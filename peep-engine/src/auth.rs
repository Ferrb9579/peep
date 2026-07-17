use std::{
    fs::File,
    io::{self, Read},
    path::Path,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use argon2::{
    Argon2, PasswordHash, PasswordHasher, PasswordVerifier,
    password_hash::{SaltString, rand_core::OsRng},
};
use base64::{Engine as _, engine::general_purpose};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Serialize;

use crate::mailbox::database_path_from_env;

#[derive(Clone)]
pub struct AuthStore {
    connection: Arc<Mutex<Connection>>,
}

#[derive(Clone, Debug, Serialize)]
pub struct AuthSession {
    pub token: String,
    pub username: String,
    pub email: String,
}

impl AuthStore {
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
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    email TEXT NOT NULL UNIQUE,
                    username TEXT NOT NULL UNIQUE,
                    password_hash TEXT NOT NULL,
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS sessions (
                    token TEXT PRIMARY KEY,
                    user_id INTEGER NOT NULL,
                    created_at INTEGER NOT NULL,
                    FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS idx_users_username ON users(username);
                CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id);
                ",
            )
            .map_err(to_io_error)?;

        Ok(Self {
            connection: Arc::new(Mutex::new(connection)),
        })
    }

    pub fn register(&self, email: &str, username: &str, password: &str) -> io::Result<AuthSession> {
        let email = normalize_email(email)?;
        let username = normalize_username(username)?;
        validate_password(password)?;

        let password_hash = hash_password(password)?;
        let created_at = unix_seconds()?;
        let token = random_token()?;
        let mut connection = self.connection.lock().map_err(lock_error)?;
        let transaction = connection.transaction().map_err(to_io_error)?;

        transaction
            .execute(
                "\
                INSERT INTO users (email, username, password_hash, created_at)
                VALUES (?1, ?2, ?3, ?4)
                ",
                params![email, username, password_hash, created_at],
            )
            .map_err(to_io_error)?;
        let user_id = transaction.last_insert_rowid();
        transaction
            .execute(
                "INSERT INTO sessions (token, user_id, created_at) VALUES (?1, ?2, ?3)",
                params![token, user_id, created_at],
            )
            .map_err(to_io_error)?;
        transaction.commit().map_err(to_io_error)?;

        Ok(AuthSession {
            token,
            username,
            email,
        })
    }

    pub fn login(&self, username: &str, password: &str) -> io::Result<Option<AuthSession>> {
        let username = normalize_username(username)?;
        let created_at = unix_seconds()?;
        let token = random_token()?;
        let mut connection = self.connection.lock().map_err(lock_error)?;
        let transaction = connection.transaction().map_err(to_io_error)?;
        let user = transaction
            .query_row(
                "SELECT id, email, password_hash FROM users WHERE username = ?1",
                params![username],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .optional()
            .map_err(to_io_error)?;

        let Some((user_id, email, password_hash)) = user else {
            return Ok(None);
        };
        if !verify_password(password, &password_hash)? {
            return Ok(None);
        }

        transaction
            .execute(
                "INSERT INTO sessions (token, user_id, created_at) VALUES (?1, ?2, ?3)",
                params![token, user_id, created_at],
            )
            .map_err(to_io_error)?;
        transaction.commit().map_err(to_io_error)?;

        Ok(Some(AuthSession {
            token,
            username,
            email,
        }))
    }

    pub fn session(&self, token: &str) -> io::Result<Option<AuthSession>> {
        let connection = self.connection.lock().map_err(lock_error)?;
        connection
            .query_row(
                "\
                SELECT sessions.token, users.username, users.email
                FROM sessions
                JOIN users ON users.id = sessions.user_id
                WHERE sessions.token = ?1
                ",
                params![token],
                |row| {
                    Ok(AuthSession {
                        token: row.get(0)?,
                        username: row.get(1)?,
                        email: row.get(2)?,
                    })
                },
            )
            .optional()
            .map_err(to_io_error)
    }

    pub fn user_exists(&self, username: &str) -> io::Result<bool> {
        let username = normalize_username(username)?;
        let connection = self.connection.lock().map_err(lock_error)?;
        let exists = connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM users WHERE username = ?1)",
                params![username],
                |row| row.get::<_, i64>(0),
            )
            .map_err(to_io_error)?;
        Ok(exists == 1)
    }
}

fn normalize_email(email: &str) -> io::Result<String> {
    let email = email.trim().to_ascii_lowercase();
    if !email.contains('@') || email.len() > 254 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "email is invalid",
        ));
    }
    Ok(email)
}

pub fn normalize_username(username: &str) -> io::Result<String> {
    let username = username.trim().to_ascii_lowercase();
    let valid = username.len() >= 3
        && username.len() <= 32
        && username
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-');
    if !valid {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "username must be 3-32 chars using letters, numbers, _ or -",
        ));
    }
    Ok(username)
}

fn validate_password(password: &str) -> io::Result<()> {
    if password.len() < 8 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "password must be at least 8 characters",
        ));
    }
    Ok(())
}

fn hash_password(password: &str) -> io::Result<String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(password_hash_error)
}

fn verify_password(password: &str, password_hash: &str) -> io::Result<bool> {
    let parsed = PasswordHash::new(password_hash).map_err(password_hash_error)?;
    Ok(Argon2::default()
        .verify_password(password.as_bytes(), &parsed)
        .is_ok())
}

fn random_token() -> io::Result<String> {
    let mut bytes = [0_u8; 32];
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

fn password_hash_error(error: argon2::password_hash::Error) -> io::Error {
    io::Error::other(error.to_string())
}

fn lock_error<T>(_: std::sync::PoisonError<T>) -> io::Error {
    io::Error::other("auth sqlite connection lock poisoned")
}
