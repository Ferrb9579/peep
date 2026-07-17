use std::{
    fs::File,
    io::{self, Read},
    path::Path,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use base64::{Engine as _, engine::general_purpose};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;

use crate::{auth::normalize_username, mailbox::database_path_from_env};

#[derive(Clone)]
pub struct GroupStore {
    connection: Arc<Mutex<Connection>>,
}

#[derive(Debug, Serialize)]
pub struct GroupSummary {
    pub id: String,
    pub name: String,
    pub members: Vec<String>,
}

impl GroupStore {
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
                CREATE TABLE IF NOT EXISTS groups (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    owner_user_id INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    FOREIGN KEY(owner_user_id) REFERENCES users(id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS group_members (
                    group_id TEXT NOT NULL,
                    user_id INTEGER NOT NULL,
                    role TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    PRIMARY KEY(group_id, user_id),
                    FOREIGN KEY(group_id) REFERENCES groups(id) ON DELETE CASCADE,
                    FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_group_members_user_id
                ON group_members(user_id);
                ",
            )
            .map_err(to_io_error)?;

        Ok(Self {
            connection: Arc::new(Mutex::new(connection)),
        })
    }

    pub fn create(
        &self,
        owner_username: &str,
        name: &str,
        members: &[String],
    ) -> io::Result<GroupSummary> {
        let owner_username = normalize_username(owner_username)?;
        let name = normalize_group_name(name)?;
        let created_at = unix_seconds()?;
        let id = random_group_id()?;
        let mut usernames = members
            .iter()
            .map(|username| normalize_username(username))
            .collect::<io::Result<Vec<_>>>()?;
        usernames.push(owner_username.clone());
        usernames.sort();
        usernames.dedup();

        if usernames.len() < 2 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "group must contain at least two users",
            ));
        }

        let mut connection = self.connection.lock().map_err(lock_error)?;
        let transaction = connection.transaction().map_err(to_io_error)?;
        let owner_id = user_id(&transaction, &owner_username)?.ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotFound, "owner username does not exist")
        })?;

        let mut member_ids = Vec::with_capacity(usernames.len());
        for username in &usernames {
            let Some(member_id) = user_id(&transaction, username)? else {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("member username does not exist: {username}"),
                ));
            };
            member_ids.push((username.clone(), member_id));
        }

        transaction
            .execute(
                "INSERT INTO groups (id, name, owner_user_id, created_at) VALUES (?1, ?2, ?3, ?4)",
                params![id, name, owner_id, created_at],
            )
            .map_err(to_io_error)?;

        for (_, member_id) in &member_ids {
            let role = if *member_id == owner_id {
                "owner"
            } else {
                "member"
            };
            transaction
                .execute(
                    "\
                    INSERT INTO group_members (group_id, user_id, role, created_at)
                    VALUES (?1, ?2, ?3, ?4)
                    ",
                    params![id, member_id, role, created_at],
                )
                .map_err(to_io_error)?;
        }

        transaction.commit().map_err(to_io_error)?;

        Ok(GroupSummary {
            id,
            name,
            members: member_ids
                .into_iter()
                .map(|(username, _)| username)
                .collect(),
        })
    }

    pub fn list_for_user(&self, username: &str) -> io::Result<Vec<GroupSummary>> {
        let username = normalize_username(username)?;
        let connection = self.connection.lock().map_err(lock_error)?;
        let Some(current_user_id) = user_id(&connection, &username)? else {
            return Ok(Vec::new());
        };

        let mut statement = connection
            .prepare(
                "\
                SELECT groups.id, groups.name
                FROM groups
                JOIN group_members ON group_members.group_id = groups.id
                WHERE group_members.user_id = ?1
                ORDER BY groups.created_at DESC
                ",
            )
            .map_err(to_io_error)?;
        let rows = statement
            .query_map(params![current_user_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .map_err(to_io_error)?;

        let mut groups = Vec::new();
        for row in rows {
            let (id, name) = row.map_err(to_io_error)?;
            groups.push(GroupSummary {
                members: members_for_group(&connection, &id)?,
                id,
                name,
            });
        }
        Ok(groups)
    }

    pub fn is_member(&self, username: &str, group_id: &str) -> io::Result<bool> {
        let username = normalize_username(username)?;
        if group_id.trim().is_empty() {
            return Ok(false);
        }

        let connection = self.connection.lock().map_err(lock_error)?;
        let exists = connection
            .query_row(
                "\
                SELECT EXISTS(
                    SELECT 1
                    FROM group_members
                    JOIN users ON users.id = group_members.user_id
                    WHERE users.username = ?1 AND group_members.group_id = ?2
                )
                ",
                params![username, group_id],
                |row| row.get::<_, i64>(0),
            )
            .map_err(to_io_error)?;
        Ok(exists == 1)
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

fn members_for_group(connection: &Connection, group_id: &str) -> io::Result<Vec<String>> {
    let mut statement = connection
        .prepare(
            "\
            SELECT users.username
            FROM group_members
            JOIN users ON users.id = group_members.user_id
            WHERE group_members.group_id = ?1
            ORDER BY users.username ASC
            ",
        )
        .map_err(to_io_error)?;
    let rows = statement
        .query_map(params![group_id], |row| row.get::<_, String>(0))
        .map_err(to_io_error)?;

    rows.map(|row| row.map_err(to_io_error)).collect()
}

fn normalize_group_name(name: &str) -> io::Result<String> {
    let name = name.trim();
    if name.is_empty() || name.len() > 80 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "group name must be 1-80 characters",
        ));
    }
    Ok(name.to_string())
}

fn random_group_id() -> io::Result<String> {
    let mut bytes = [0_u8; 18];
    File::open("/dev/urandom")?.read_exact(&mut bytes)?;
    Ok(general_purpose::URL_SAFE_NO_PAD.encode(bytes))
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
    io::Error::other("groups sqlite connection lock poisoned")
}
