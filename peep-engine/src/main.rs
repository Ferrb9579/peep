use std::{collections::HashMap, io, sync::Arc};

use serde_json::{Value, json};
use tokio::{
    io::AsyncWriteExt,
    net::{TcpListener, TcpStream, tcp::OwnedReadHalf},
    sync::{Mutex, mpsc},
};

mod mailbox;
mod websocket;

use mailbox::MailboxStore;
use websocket::{
    header_value, parse_query, read_http_request, read_text_frame, websocket_accept_key,
    write_text_frame,
};

type PeerSender = mpsc::UnboundedSender<String>;
type Rooms = Arc<Mutex<HashMap<String, HashMap<String, PeerSender>>>>;

#[tokio::main]
async fn main() -> io::Result<()> {
    let addr = std::env::var("PEEP_ENGINE_ADDR").unwrap_or_else(|_| "127.0.0.1:8787".to_string());
    let listener = TcpListener::bind(&addr).await?;
    let rooms: Rooms = Arc::new(Mutex::new(HashMap::new()));
    let mailbox = MailboxStore::open_from_env()?;

    println!("peep-engine signaling server listening on ws://{addr}/ws?room=demo&peer=alice");

    loop {
        let (stream, _) = listener.accept().await?;
        let rooms = Arc::clone(&rooms);
        let mailbox = mailbox.clone();

        tokio::spawn(async move {
            if let Err(error) = handle_connection(stream, rooms, mailbox).await {
                eprintln!("connection closed: {error}");
            }
        });
    }
}

async fn handle_connection(
    mut stream: TcpStream,
    rooms: Rooms,
    mailbox: MailboxStore,
) -> io::Result<()> {
    let request = read_http_request(&mut stream).await?;
    let key = header_value(&request, "sec-websocket-key")
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing websocket key"))?;
    let (room, peer) = parse_query(&request);

    let accept = websocket_accept_key(&key);
    let response = format!(
        "HTTP/1.1 101 Switching Protocols\r\n\
         Upgrade: websocket\r\n\
         Connection: Upgrade\r\n\
         Sec-WebSocket-Accept: {accept}\r\n\r\n"
    );
    stream.write_all(response.as_bytes()).await?;

    let (reader, mut writer) = stream.into_split();
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();

    let room_is_full = {
        let rooms = rooms.lock().await;
        rooms.get(&room).is_some_and(|peers| peers.len() >= 2)
    };

    if room_is_full {
        write_text_frame(
            &mut writer,
            &json!({
                "type": "error",
                "message": "Room is full. Disconnect one tab or use a different room.",
            })
            .to_string(),
        )
        .await?;
        return Ok(());
    }

    let existing_peers = {
        let mut rooms = rooms.lock().await;
        let peers = rooms.entry(room.clone()).or_default();
        let existing_peers = peers.len();
        peers.insert(peer.clone(), tx.clone());
        existing_peers
    };

    let _ = tx.send(
        json!({
            "type": "welcome",
            "room": room,
            "peer": peer,
            "existingPeers": existing_peers,
        })
        .to_string(),
    );
    deliver_stored_messages(&mailbox, &room, &peer, &tx);

    println!("peer {peer} joined room {room}");
    broadcast(
        &rooms,
        &room,
        &peer,
        json!({"type": "presence", "event": "joined", "peer": peer}).to_string(),
    )
    .await;

    let writer_task = tokio::spawn(async move {
        let mut writer = writer;
        while let Some(message) = rx.recv().await {
            if write_text_frame(&mut writer, &message).await.is_err() {
                break;
            }
        }
    });

    let read_result = read_loop(
        reader,
        Arc::clone(&rooms),
        mailbox,
        room.clone(),
        peer.clone(),
    )
    .await;

    {
        let mut rooms = rooms.lock().await;
        if let Some(peers) = rooms.get_mut(&room) {
            peers.remove(&peer);
            if peers.is_empty() {
                rooms.remove(&room);
            }
        }
    }

    broadcast(
        &rooms,
        &room,
        &peer,
        json!({"type": "presence", "event": "left", "peer": peer}).to_string(),
    )
    .await;

    writer_task.abort();
    read_result
}

async fn read_loop(
    mut reader: OwnedReadHalf,
    rooms: Rooms,
    mailbox: MailboxStore,
    room: String,
    peer: String,
) -> io::Result<()> {
    while let Some(message) = read_text_frame(&mut reader).await? {
        if store_message(&mailbox, &room, &peer, &message) {
            continue;
        }

        let outgoing = match serde_json::from_str::<Value>(&message) {
            Ok(mut value) => {
                if let Some(object) = value.as_object_mut() {
                    object.insert("from".to_string(), Value::String(peer.clone()));
                }
                value.to_string()
            }
            Err(_) => json!({"type": "message", "from": peer, "body": message}).to_string(),
        };

        broadcast(&rooms, &room, &peer, outgoing).await;
    }

    Ok(())
}

fn store_message(mailbox: &MailboxStore, room: &str, peer: &str, raw: &str) -> bool {
    let Ok(value) = serde_json::from_str::<Value>(raw) else {
        return false;
    };
    if value.get("type").and_then(Value::as_str) != Some("store") {
        return false;
    }
    let Some(payload) = value.get("payload") else {
        return true;
    };

    match mailbox.store(room, peer, payload) {
        Ok(()) => println!("stored encrypted payload from {peer} in room {room}"),
        Err(error) => eprintln!("failed to persist encrypted mailbox payload: {error}"),
    }
    true
}

fn deliver_stored_messages(mailbox: &MailboxStore, room: &str, peer: &str, tx: &PeerSender) {
    match mailbox.take_for_peer(room, peer) {
        Ok(messages) => {
            for message in messages {
                let _ = tx.send(message);
            }
        }
        Err(error) => eprintln!("failed to read encrypted mailbox: {error}"),
    }
}

async fn broadcast(rooms: &Rooms, room: &str, sender: &str, message: String) {
    let peers = {
        let rooms = rooms.lock().await;
        rooms
            .get(room)
            .map(|room_peers| {
                room_peers
                    .iter()
                    .filter(|(peer, _)| peer.as_str() != sender)
                    .map(|(_, tx)| tx.clone())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    };

    for peer in peers {
        let _ = peer.send(message.clone());
    }
}
