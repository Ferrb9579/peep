use std::{
    collections::HashMap,
    io,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

use rusqlite::{Connection, params};
use serde::Serialize;
use serde_json::{Value, json};

const DEFAULT_MAILBOX_PATH: &str = "peep-mailboxes.sqlite3";
const MAX_STORED_MESSAGES_PER_ROOM: i64 = 5000;

#[derive(Clone)]
pub struct MailboxStore {
    connection: Arc<Mutex<Connection>>,
}

#[derive(Debug, Serialize)]
pub struct MailboxSummary {
    pub room: String,
    #[serde(rename = "contactUsername")]
    pub contact_username: String,
    #[serde(rename = "unreadCount")]
    pub unread_count: i64,
    #[serde(rename = "updatedAt")]
    pub updated_at: i64,
}

impl MailboxStore {
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
                CREATE TABLE IF NOT EXISTS mailbox_messages (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    room TEXT NOT NULL,
                    sender TEXT NOT NULL,
                    payload TEXT NOT NULL,
                    created_at INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_mailbox_room_id
                    ON mailbox_messages(room, id);
                CREATE INDEX IF NOT EXISTS idx_mailbox_room_sender
                    ON mailbox_messages(room, sender);
                ",
            )
            .map_err(to_io_error)?;

        println!("encrypted mailbox sqlite path: {}", path.display());

        Ok(Self {
            connection: Arc::new(Mutex::new(connection)),
        })
    }

    pub fn store(&self, room: &str, sender: &str, payload: &Value) -> io::Result<()> {
        let payload = serde_json::to_string(payload).map_err(to_io_error)?;
        let created_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(to_io_error)?
            .as_secs() as i64;
        let connection = self.connection.lock().map_err(lock_error)?;

        connection
            .execute(
                "\
                INSERT INTO mailbox_messages (room, sender, payload, created_at)
                VALUES (?1, ?2, ?3, ?4)
                ",
                params![room, sender, payload, created_at],
            )
            .map_err(to_io_error)?;
        connection
            .execute(
                "\
                DELETE FROM mailbox_messages
                WHERE room = ?1
                  AND id NOT IN (
                      SELECT id FROM mailbox_messages
                      WHERE room = ?1
                      ORDER BY id DESC
                      LIMIT ?2
                  )
                ",
                params![room, MAX_STORED_MESSAGES_PER_ROOM],
            )
            .map_err(to_io_error)?;

        Ok(())
    }

    pub fn take_for_peer(&self, room: &str, peer: &str) -> io::Result<Vec<String>> {
        let mut connection = self.connection.lock().map_err(lock_error)?;
        let transaction = connection.transaction().map_err(to_io_error)?;

        let rows = {
            let mut statement = transaction
                .prepare(
                    "\
                    SELECT id, sender, payload
                    FROM mailbox_messages
                    WHERE room = ?1 AND sender != ?2
                    ORDER BY id ASC
                    ",
                )
                .map_err(to_io_error)?;

            let rows = statement
                .query_map(params![room, peer], |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                })
                .map_err(to_io_error)?;

            let mut rows_out = Vec::new();
            for row in rows {
                rows_out.push(row.map_err(to_io_error)?);
            }
            rows_out
        };

        for (id, _, _) in &rows {
            transaction
                .execute("DELETE FROM mailbox_messages WHERE id = ?1", params![id])
                .map_err(to_io_error)?;
        }
        transaction.commit().map_err(to_io_error)?;

        rows.into_iter()
            .map(|(_, sender, payload)| {
                let payload: Value = serde_json::from_str(&payload).map_err(to_io_error)?;
                Ok(json!({
                    "type": "stored",
                    "from": sender,
                    "payload": payload,
                })
                .to_string())
            })
            .collect()
    }

    pub fn list_for_peer(&self, peer: &str) -> io::Result<Vec<MailboxSummary>> {
        let connection = self.connection.lock().map_err(lock_error)?;
        let mut statement = connection
            .prepare(
                "\
                SELECT room, sender, COUNT(*) AS unread_count, MAX(created_at) AS updated_at
                FROM mailbox_messages
                WHERE sender != ?1
                  AND room LIKE 'dm:%'
                GROUP BY room, sender
                ",
            )
            .map_err(to_io_error)?;

        let rows = statement
            .query_map(params![peer], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            })
            .map_err(to_io_error)?;

        let mut summaries_by_contact = HashMap::<String, MailboxSummary>::new();
        for row in rows {
            let (room, sender, unread_count, updated_at) = row.map_err(to_io_error)?;
            let Some(contact_username) = direct_room_contact(&room, peer) else {
                continue;
            };
            if contact_username != sender {
                continue;
            }

            summaries_by_contact
                .entry(contact_username.clone())
                .and_modify(|summary| {
                    summary.unread_count += unread_count;
                    if updated_at > summary.updated_at {
                        summary.updated_at = updated_at;
                        summary.room = room.clone();
                    }
                })
                .or_insert(MailboxSummary {
                    room,
                    contact_username,
                    unread_count,
                    updated_at,
                });
        }

        let mut summaries = summaries_by_contact.into_values().collect::<Vec<_>>();
        summaries.sort_by(|a, b| b.updated_at.cmp(&a.updated_at));
        Ok(summaries)
    }
}

fn direct_room_contact(room: &str, peer: &str) -> Option<String> {
    let mut parts = room.split(':');
    if parts.next()? != "dm" {
        return None;
    }
    let first = parts.next()?;
    let second = parts.next()?;
    if parts.next().is_some() {
        return None;
    }

    if first == peer {
        Some(second.to_string())
    } else if second == peer {
        Some(first.to_string())
    } else {
        None
    }
}

pub fn database_path_from_env() -> PathBuf {
    std::env::var("PEEP_MAILBOX_PATH")
        .or_else(|_| std::env::var("PEEP_DB_PATH"))
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from(DEFAULT_MAILBOX_PATH))
}

fn to_io_error(error: impl std::error::Error + Send + Sync + 'static) -> io::Error {
    io::Error::other(error)
}

fn lock_error<T>(_: std::sync::PoisonError<T>) -> io::Error {
    io::Error::other("mailbox sqlite connection lock poisoned")
}
