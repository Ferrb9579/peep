use std::{
    io,
    path::Path,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;

use crate::{auth::normalize_username, mailbox::database_path_from_env};

#[derive(Clone)]
pub struct ConferenceStore {
    connection: Arc<Mutex<Connection>>,
}

#[derive(Debug, Serialize)]
pub struct ConferenceSession {
    #[serde(rename = "groupId")]
    pub group_id: String,
    pub mode: String,
    #[serde(rename = "memberCount")]
    pub member_count: i64,
    #[serde(rename = "sfuRequired")]
    pub sfu_required: bool,
    #[serde(rename = "createdBy")]
    pub created_by: String,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
}

impl ConferenceStore {
    pub fn open_from_env() -> io::Result<Self> {
        Self::open(database_path_from_env())
    }

    pub fn open(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref();
        if let Some(parent) = path
            .parent()
            .filter(|parent| !parent.as_os_str().is_empty())
        {
            std::fs::create_dir_all(parent)?;
        }

        let connection = Connection::open(path).map_err(to_io_error)?;
        connection
            .execute_batch(
                "\
                PRAGMA journal_mode = WAL;
                PRAGMA foreign_keys = ON;
                CREATE TABLE IF NOT EXISTS conference_sessions (
                    group_id TEXT PRIMARY KEY,
                    mode TEXT NOT NULL,
                    created_by_user_id INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    active INTEGER NOT NULL,
                    FOREIGN KEY(group_id) REFERENCES groups(id) ON DELETE CASCADE,
                    FOREIGN KEY(created_by_user_id) REFERENCES users(id) ON DELETE CASCADE
                );
                ",
            )
            .map_err(to_io_error)?;

        Ok(Self {
            connection: Arc::new(Mutex::new(connection)),
        })
    }

    pub fn start(&self, requester: &str, group_id: &str) -> io::Result<ConferenceSession> {
        let requester = normalize_username(requester)?;
        let created_at = unix_seconds()?;
        let connection = self.connection.lock().map_err(lock_error)?;
        let requester_id = user_id(&connection, &requester)?
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "username does not exist"))?;
        ensure_group_member_by_id(&connection, requester_id, group_id)?;
        let member_count = group_member_count(&connection, group_id)?;
        let mode = if member_count <= 2 {
            "peer-to-peer"
        } else {
            "sfu"
        };

        connection
            .execute(
                "\
                INSERT INTO conference_sessions
                (group_id, mode, created_by_user_id, created_at, active)
                VALUES (?1, ?2, ?3, ?4, 1)
                ON CONFLICT(group_id)
                DO UPDATE SET
                    mode = excluded.mode,
                    created_by_user_id = excluded.created_by_user_id,
                    created_at = excluded.created_at,
                    active = 1
                ",
                params![group_id, mode, requester_id, created_at],
            )
            .map_err(to_io_error)?;

        Ok(ConferenceSession {
            group_id: group_id.to_string(),
            mode: mode.to_string(),
            member_count,
            sfu_required: mode == "sfu",
            created_by: requester,
            created_at,
        })
    }

    pub fn status(&self, requester: &str, group_id: &str) -> io::Result<Option<ConferenceSession>> {
        let requester = normalize_username(requester)?;
        let connection = self.connection.lock().map_err(lock_error)?;
        let requester_id = user_id(&connection, &requester)?
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "username does not exist"))?;
        ensure_group_member_by_id(&connection, requester_id, group_id)?;
        let member_count = group_member_count(&connection, group_id)?;

        connection
            .query_row(
                "\
                SELECT conference_sessions.group_id,
                       conference_sessions.mode,
                       users.username,
                       conference_sessions.created_at
                FROM conference_sessions
                JOIN users ON users.id = conference_sessions.created_by_user_id
                WHERE conference_sessions.group_id = ?1
                  AND conference_sessions.active = 1
                ",
                params![group_id],
                |row| {
                    let mode: String = row.get(1)?;
                    Ok(ConferenceSession {
                        group_id: row.get(0)?,
                        sfu_required: mode == "sfu",
                        mode,
                        member_count,
                        created_by: row.get(2)?,
                        created_at: row.get(3)?,
                    })
                },
            )
            .optional()
            .map_err(to_io_error)
    }

    pub fn end(&self, requester: &str, group_id: &str) -> io::Result<()> {
        let requester = normalize_username(requester)?;
        let connection = self.connection.lock().map_err(lock_error)?;
        let requester_id = user_id(&connection, &requester)?
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "username does not exist"))?;
        ensure_group_member_by_id(&connection, requester_id, group_id)?;
        connection
            .execute(
                "UPDATE conference_sessions SET active = 0 WHERE group_id = ?1",
                params![group_id],
            )
            .map_err(to_io_error)?;
        Ok(())
    }
}

fn user_id(connection: &Connection, username: &str) -> io::Result<Option<i64>> {
    connection
        .query_row(
            "SELECT id FROM users WHERE username = ?1",
            params![username],
            |row| row.get(0),
        )
        .optional()
        .map_err(to_io_error)
}

fn group_member_count(connection: &Connection, group_id: &str) -> io::Result<i64> {
    connection
        .query_row(
            "SELECT COUNT(*) FROM group_members WHERE group_id = ?1",
            params![group_id],
            |row| row.get(0),
        )
        .map_err(to_io_error)
}

fn ensure_group_member_by_id(
    connection: &Connection,
    user_id: i64,
    group_id: &str,
) -> io::Result<()> {
    let exists = connection
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM group_members WHERE group_id = ?1 AND user_id = ?2)",
            params![group_id, user_id],
            |row| row.get::<_, i64>(0),
        )
        .map_err(to_io_error)?;
    if exists == 1 {
        return Ok(());
    }

    Err(io::Error::new(
        io::ErrorKind::PermissionDenied,
        "user is not a member of this group",
    ))
}

fn unix_seconds() -> io::Result<i64> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(to_io_error)?
        .as_secs() as i64)
}

fn to_io_error(error: impl std::error::Error + Send + Sync + 'static) -> io::Error {
    io::Error::other(error)
}

fn lock_error<T>(_: std::sync::PoisonError<T>) -> io::Error {
    io::Error::other("conference sqlite connection lock poisoned")
}
