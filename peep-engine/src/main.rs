use std::{collections::HashMap, io, sync::Arc};

use base64::{Engine as _, engine::general_purpose};
use serde_json::{Value, json};
use sha1::{Digest, Sha1};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream, tcp::OwnedReadHalf, tcp::OwnedWriteHalf},
    sync::{Mutex, mpsc},
};

const WEBSOCKET_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

type PeerSender = mpsc::UnboundedSender<String>;
type Rooms = Arc<Mutex<HashMap<String, HashMap<String, PeerSender>>>>;

#[tokio::main]
async fn main() -> io::Result<()> {
    let addr = std::env::var("PEEP_ENGINE_ADDR").unwrap_or_else(|_| "127.0.0.1:8787".to_string());
    let listener = TcpListener::bind(&addr).await?;
    let rooms: Rooms = Arc::new(Mutex::new(HashMap::new()));

    println!("peep-engine signaling server listening on ws://{addr}/ws?room=demo&peer=alice");

    loop {
        let (stream, _) = listener.accept().await?;
        let rooms = Arc::clone(&rooms);

        tokio::spawn(async move {
            if let Err(error) = handle_connection(stream, rooms).await {
                eprintln!("connection closed: {error}");
            }
        });
    }
}

async fn handle_connection(mut stream: TcpStream, rooms: Rooms) -> io::Result<()> {
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

    let read_result = read_loop(reader, Arc::clone(&rooms), room.clone(), peer.clone()).await;

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
    room: String,
    peer: String,
) -> io::Result<()> {
    while let Some(message) = read_text_frame(&mut reader).await? {
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

async fn read_http_request(stream: &mut TcpStream) -> io::Result<String> {
    let mut buffer = Vec::with_capacity(2048);
    let mut byte = [0_u8; 1];

    while !buffer.ends_with(b"\r\n\r\n") {
        let read = stream.read(&mut byte).await?;
        if read == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "request ended early",
            ));
        }
        buffer.push(byte[0]);
        if buffer.len() > 8192 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "request too large",
            ));
        }
    }

    String::from_utf8(buffer)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "request is not utf-8"))
}

fn header_value(request: &str, name: &str) -> Option<String> {
    request.lines().find_map(|line| {
        let (key, value) = line.split_once(':')?;
        key.eq_ignore_ascii_case(name)
            .then(|| value.trim().to_string())
    })
}

fn parse_query(request: &str) -> (String, String) {
    let path = request
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .unwrap_or("/ws");

    let query = path
        .split_once('?')
        .map(|(_, query)| query)
        .unwrap_or_default();
    let mut room = "demo".to_string();
    let mut peer = format!("peer-{}", std::process::id());

    for part in query.split('&') {
        let Some((key, value)) = part.split_once('=') else {
            continue;
        };

        match key {
            "room" if !value.is_empty() => room = percent_decode(value),
            "peer" if !value.is_empty() => peer = percent_decode(value),
            _ => {}
        }
    }

    (room, peer)
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        match bytes[index] {
            b'%' if index + 2 < bytes.len() => {
                let hex = &value[index + 1..index + 3];
                if let Ok(byte) = u8::from_str_radix(hex, 16) {
                    decoded.push(byte);
                    index += 3;
                    continue;
                }
                decoded.push(bytes[index]);
            }
            b'+' => decoded.push(b' '),
            byte => decoded.push(byte),
        }
        index += 1;
    }

    String::from_utf8_lossy(&decoded).to_string()
}

fn websocket_accept_key(key: &str) -> String {
    let mut hasher = Sha1::new();
    hasher.update(key.as_bytes());
    hasher.update(WEBSOCKET_GUID.as_bytes());
    general_purpose::STANDARD.encode(hasher.finalize())
}

async fn read_text_frame(reader: &mut OwnedReadHalf) -> io::Result<Option<String>> {
    let mut header = [0_u8; 2];
    if reader.read_exact(&mut header).await.is_err() {
        return Ok(None);
    }

    let opcode = header[0] & 0x0f;
    if opcode == 0x8 {
        return Ok(None);
    }

    let masked = header[1] & 0x80 != 0;
    let mut length = u64::from(header[1] & 0x7f);

    if length == 126 {
        let mut extended = [0_u8; 2];
        reader.read_exact(&mut extended).await?;
        length = u64::from(u16::from_be_bytes(extended));
    } else if length == 127 {
        let mut extended = [0_u8; 8];
        reader.read_exact(&mut extended).await?;
        length = u64::from_be_bytes(extended);
    }

    if length > 64 * 1024 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame too large",
        ));
    }

    let mut mask = [0_u8; 4];
    if masked {
        reader.read_exact(&mut mask).await?;
    }

    let mut payload = vec![0_u8; length as usize];
    reader.read_exact(&mut payload).await?;

    if masked {
        for (index, byte) in payload.iter_mut().enumerate() {
            *byte ^= mask[index % 4];
        }
    }

    if opcode != 0x1 {
        return Ok(Some(String::new()));
    }

    String::from_utf8(payload)
        .map(Some)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "text frame is not utf-8"))
}

async fn write_text_frame(writer: &mut OwnedWriteHalf, message: &str) -> io::Result<()> {
    let bytes = message.as_bytes();
    let mut frame = Vec::with_capacity(bytes.len() + 10);
    frame.push(0x81);

    if bytes.len() < 126 {
        frame.push(bytes.len() as u8);
    } else if bytes.len() <= u16::MAX as usize {
        frame.push(126);
        frame.extend_from_slice(&(bytes.len() as u16).to_be_bytes());
    } else {
        frame.push(127);
        frame.extend_from_slice(&(bytes.len() as u64).to_be_bytes());
    }

    frame.extend_from_slice(bytes);
    writer.write_all(&frame).await
}
