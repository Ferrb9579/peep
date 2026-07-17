use std::{
    io,
    path::Path,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

use crate::{auth::normalize_username, mailbox::database_path_from_env};

#[derive(Clone)]
pub struct KeyStore {
    connection: Arc<Mutex<Connection>>,
}

#[derive(Debug, Serialize)]
pub struct MemberPublicKey {
    pub username: String,
    #[serde(rename = "publicKey")]
    pub public_key: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct GroupKeyEnvelopeInput {
    pub username: String,
    #[serde(rename = "encryptedKey")]
    pub encrypted_key: String,
}

impl KeyStore {
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
                CREATE TABLE IF NOT EXISTS identity_keys (
                    user_id INTEGER PRIMARY KEY,
                    public_key TEXT NOT NULL,
                    updated_at INTEGER NOT NULL,
                    FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
                );
                CREATE TABLE IF NOT EXISTS group_key_envelopes (
                    group_id TEXT NOT NULL,
                    user_id INTEGER NOT NULL,
                    encrypted_key TEXT NOT NULL,
                    updated_at INTEGER NOT NULL,
                    PRIMARY KEY(group_id, user_id),
                    FOREIGN KEY(group_id) REFERENCES groups(id) ON DELETE CASCADE,
                    FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
                );
                ",
            )
            .map_err(to_io_error)?;

        Ok(Self {
            connection: Arc::new(Mutex::new(connection)),
        })
    }

    pub fn update_identity_key(&self, username: &str, public_key: &str) -> io::Result<()> {
        let username = normalize_username(username)?;
        let public_key = normalize_public_key(public_key)?;
        let updated_at = unix_seconds()?;
        let connection = self.connection.lock().map_err(lock_error)?;
        let user_id = user_id(&connection, &username)?
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "username does not exist"))?;

        connection
            .execute(
                "\
                INSERT INTO identity_keys (user_id, public_key, updated_at)
                VALUES (?1, ?2, ?3)
                ON CONFLICT(user_id)
                DO UPDATE SET public_key = excluded.public_key, updated_at = excluded.updated_at
                ",
                params![user_id, public_key, updated_at],
            )
            .map_err(to_io_error)?;
        Ok(())
    }

    pub fn group_member_public_keys(
        &self,
        requester: &str,
        group_id: &str,
    ) -> io::Result<Vec<MemberPublicKey>> {
        let requester = normalize_username(requester)?;
        let connection = self.connection.lock().map_err(lock_error)?;
        ensure_group_member(&connection, &requester, group_id)?;

        let mut statement = connection
            .prepare(
                "\
                SELECT users.username, identity_keys.public_key
                FROM group_members
                JOIN users ON users.id = group_members.user_id
                LEFT JOIN identity_keys ON identity_keys.user_id = users.id
                WHERE group_members.group_id = ?1
                ORDER BY users.username ASC
                ",
            )
            .map_err(to_io_error)?;
        let rows = statement
            .query_map(params![group_id], |row| {
                Ok(MemberPublicKey {
                    username: row.get(0)?,
                    public_key: row.get(1)?,
                })
            })
            .map_err(to_io_error)?;

        rows.map(|row| row.map_err(to_io_error)).collect()
    }

    pub fn update_group_key_envelopes(
        &self,
        requester: &str,
        group_id: &str,
        envelopes: &[GroupKeyEnvelopeInput],
    ) -> io::Result<()> {
        let requester = normalize_username(requester)?;
        let updated_at = unix_seconds()?;
        let mut connection = self.connection.lock().map_err(lock_error)?;
        ensure_group_member(&connection, &requester, group_id)?;
        let transaction = connection.transaction().map_err(to_io_error)?;

        for envelope in envelopes {
            let username = normalize_username(&envelope.username)?;
            let encrypted_key = normalize_encrypted_key(&envelope.encrypted_key)?;
            let user_id = user_id(&transaction, &username)?.ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    format!("member username does not exist: {username}"),
                )
            })?;
            ensure_group_member_by_id(&transaction, user_id, group_id)?;
            transaction
                .execute(
                    "\
                    INSERT INTO group_key_envelopes
                    (group_id, user_id, encrypted_key, updated_at)
                    VALUES (?1, ?2, ?3, ?4)
                    ON CONFLICT(group_id, user_id)
                    DO UPDATE SET
                        encrypted_key = excluded.encrypted_key,
                        updated_at = excluded.updated_at
                    ",
                    params![group_id, user_id, encrypted_key, updated_at],
                )
                .map_err(to_io_error)?;
        }

        transaction.commit().map_err(to_io_error)
    }

    pub fn group_key_envelope(&self, username: &str, group_id: &str) -> io::Result<Option<String>> {
        let username = normalize_username(username)?;
        let connection = self.connection.lock().map_err(lock_error)?;
        let user_id = user_id(&connection, &username)?
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "username does not exist"))?;
        ensure_group_member_by_id(&connection, user_id, group_id)?;

        connection
            .query_row(
                "\
                SELECT encrypted_key
                FROM group_key_envelopes
                WHERE group_id = ?1 AND user_id = ?2
                ",
                params![group_id, user_id],
                |row| row.get(0),
            )
            .optional()
            .map_err(to_io_error)
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

fn ensure_group_member(connection: &Connection, username: &str, group_id: &str) -> io::Result<()> {
    let user_id = user_id(connection, username)?
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "username does not exist"))?;
    ensure_group_member_by_id(connection, user_id, group_id)
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

fn normalize_public_key(public_key: &str) -> io::Result<String> {
    normalize_key_material(public_key, "public key")
}

fn normalize_encrypted_key(encrypted_key: &str) -> io::Result<String> {
    normalize_key_material(encrypted_key, "encrypted key")
}

fn normalize_key_material(value: &str, label: &str) -> io::Result<String> {
    let value = value.trim();
    if value.is_empty() || value.len() > 16 * 1024 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("{label} is invalid"),
        ));
    }
    Ok(value.to_string())
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
    io::Error::other("keys sqlite connection lock poisoned")
}
