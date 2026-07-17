use std::{collections::HashMap, io, sync::Arc};

use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream, tcp::OwnedReadHalf},
    sync::{Mutex, mpsc},
};

mod auth;
mod conference;
mod groups;
mod keys;
mod mailbox;
mod sfu;
mod websocket;

use auth::{AuthStore, normalize_username};
use conference::ConferenceStore;
use groups::GroupStore;
use keys::KeyStore;
use mailbox::MailboxStore;
use sfu::SfuServer;
use websocket::{
    header_value, parse_query, query_param, read_http_request, read_text_frame, request_method,
    request_path, websocket_accept_key, write_text_frame,
};

type PeerSender = mpsc::UnboundedSender<String>;
type Rooms = Arc<Mutex<HashMap<String, HashMap<String, PeerSender>>>>;

#[tokio::main]
async fn main() -> io::Result<()> {
    let addr = std::env::var("PEEP_ENGINE_ADDR").unwrap_or_else(|_| "127.0.0.1:8787".to_string());
    let listener = TcpListener::bind(&addr).await?;
    let rooms: Rooms = Arc::new(Mutex::new(HashMap::new()));
    let mailbox = MailboxStore::open_from_env()?;
    let auth = AuthStore::open_from_env()?;
    let groups = GroupStore::open_from_env()?;
    let keys = KeyStore::open_from_env()?;
    let conferences = ConferenceStore::open_from_env()?;
    let sfu = SfuServer::new()?;

    println!("peep-engine signaling server listening on ws://{addr}/ws?room=demo&peer=alice");

    loop {
        let (stream, _) = listener.accept().await?;
        let rooms = Arc::clone(&rooms);
        let mailbox = mailbox.clone();
        let auth = auth.clone();
        let groups = groups.clone();
        let keys = keys.clone();
        let conferences = conferences.clone();
        let sfu = sfu.clone();

        tokio::spawn(async move {
            if let Err(error) =
                handle_connection(stream, rooms, mailbox, auth, groups, keys, conferences, sfu)
                    .await
            {
                eprintln!("connection closed: {error}");
            }
        });
    }
}

async fn handle_connection(
    mut stream: TcpStream,
    rooms: Rooms,
    mailbox: MailboxStore,
    auth: AuthStore,
    groups: GroupStore,
    keys: KeyStore,
    conferences: ConferenceStore,
    sfu: SfuServer,
) -> io::Result<()> {
    let request = read_http_request(&mut stream).await?;
    if !is_websocket_request(&request) {
        return handle_api_request(
            stream,
            &request,
            &mailbox,
            &auth,
            &groups,
            &keys,
            &conferences,
            &sfu,
        )
        .await;
    }

    let key = header_value(&request, "sec-websocket-key")
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing websocket key"))?;
    let (room, peer) = match authenticated_route(&request, &auth, &groups) {
        Ok(Some(route)) => route,
        Ok(None) => parse_query(&request),
        Err(error) => {
            write_json_response(&mut stream, 401, json!({"error": error.to_string()})).await?;
            return Ok(());
        }
    };

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
        !room.starts_with("group:")
            && rooms
                .get(&room)
                .is_some_and(|peers| peers.len() >= 2 && !peers.contains_key(&peer))
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
            // A user may reconnect before an older socket notices that it has
            // closed. Only remove this connection's sender so the stale socket
            // cannot evict the replacement connection from the room.
            if peers
                .get(&peer)
                .is_some_and(|current| current.same_channel(&tx))
            {
                peers.remove(&peer);
            }
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

async fn handle_api_request(
    mut stream: TcpStream,
    request: &str,
    mailbox: &MailboxStore,
    auth: &AuthStore,
    groups: &GroupStore,
    keys: &KeyStore,
    conferences: &ConferenceStore,
    sfu: &SfuServer,
) -> io::Result<()> {
    let method = request_method(request);
    let path = request_path(request)
        .split_once('?')
        .map(|(path, _)| path)
        .unwrap_or_else(|| request_path(request));

    if method == "OPTIONS" {
        return write_empty_response(&mut stream, 204).await;
    }

    match (method, path) {
        ("GET", "/health") => {
            write_json_response(&mut stream, 200, json!({"status": "ok"})).await
        }
        ("POST", "/api/register") => {
            let body = read_json_body(&mut stream, request).await?;
            let email = body
                .get("email")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let username = body
                .get("username")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let password = body
                .get("password")
                .and_then(Value::as_str)
                .unwrap_or_default();
            match auth.register(email, username, password) {
                Ok(session) => write_json_response(&mut stream, 200, json!(session)).await,
                Err(error) => {
                    write_json_response(&mut stream, 400, json!({"error": error.to_string()})).await
                }
            }
        }
        ("POST", "/api/login") => {
            let body = read_json_body(&mut stream, request).await?;
            let username = body
                .get("username")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let password = body
                .get("password")
                .and_then(Value::as_str)
                .unwrap_or_default();
            match auth.login(username, password) {
                Ok(Some(session)) => write_json_response(&mut stream, 200, json!(session)).await,
                Ok(None) => {
                    write_json_response(&mut stream, 401, json!({"error": "invalid credentials"}))
                        .await
                }
                Err(error) => {
                    write_json_response(&mut stream, 400, json!({"error": error.to_string()})).await
                }
            }
        }
        ("POST", "/api/groups/create") => {
            let body = read_json_body(&mut stream, request).await?;
            let session = session_from_body(auth, &body)?;
            let name = body.get("name").and_then(Value::as_str).unwrap_or_default();
            let members = body
                .get("members")
                .and_then(Value::as_array)
                .map(|members| {
                    members
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_string)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            match groups.create(&session.username, name, &members) {
                Ok(group) => write_json_response(&mut stream, 200, json!(group)).await,
                Err(error) => {
                    write_json_response(&mut stream, 400, json!({"error": error.to_string()})).await
                }
            }
        }
        ("POST", "/api/groups/list") => {
            let body = read_json_body(&mut stream, request).await?;
            match session_from_body(auth, &body)
                .and_then(|session| groups.list_for_user(&session.username))
            {
                Ok(groups) => {
                    write_json_response(&mut stream, 200, json!({"groups": groups})).await
                }
                Err(error) => {
                    write_json_response(&mut stream, 400, json!({"error": error.to_string()})).await
                }
            }
        }
        ("POST", "/api/identity-key/update") => {
            let body = read_json_body(&mut stream, request).await?;
            let session = session_from_body(auth, &body)?;
            let public_key = body
                .get("publicKey")
                .and_then(Value::as_str)
                .unwrap_or_default();
            match keys.update_identity_key(&session.username, public_key) {
                Ok(()) => write_json_response(&mut stream, 200, json!({"ok": true})).await,
                Err(error) => {
                    write_json_response(&mut stream, 400, json!({"error": error.to_string()})).await
                }
            }
        }
        ("POST", "/api/groups/member-keys") => {
            let body = read_json_body(&mut stream, request).await?;
            let session = session_from_body(auth, &body)?;
            let group_id = body
                .get("groupId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            match keys.group_member_public_keys(&session.username, group_id) {
                Ok(members) => {
                    write_json_response(&mut stream, 200, json!({"members": members})).await
                }
                Err(error) => {
                    write_json_response(&mut stream, 400, json!({"error": error.to_string()})).await
                }
            }
        }
        ("POST", "/api/groups/key-envelopes/update") => {
            let body = read_json_body(&mut stream, request).await?;
            let session = session_from_body(auth, &body)?;
            let group_id = body
                .get("groupId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let envelopes = body
                .get("envelopes")
                .cloned()
                .map(serde_json::from_value::<Vec<keys::GroupKeyEnvelopeInput>>)
                .transpose()
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "envelopes are invalid"))?
                .unwrap_or_default();
            match keys.update_group_key_envelopes(&session.username, group_id, &envelopes) {
                Ok(()) => write_json_response(&mut stream, 200, json!({"ok": true})).await,
                Err(error) => {
                    write_json_response(&mut stream, 400, json!({"error": error.to_string()})).await
                }
            }
        }
        ("POST", "/api/groups/key-envelope") => {
            let body = read_json_body(&mut stream, request).await?;
            let session = session_from_body(auth, &body)?;
            let group_id = body
                .get("groupId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            match keys.group_key_envelope(&session.username, group_id) {
                Ok(encrypted_key) => {
                    write_json_response(&mut stream, 200, json!({"encryptedKey": encrypted_key}))
                        .await
                }
                Err(error) => {
                    write_json_response(&mut stream, 400, json!({"error": error.to_string()})).await
                }
            }
        }
        ("POST", "/api/mailbox/list") => {
            let body = read_json_body(&mut stream, request).await?;
            let session = session_from_body(auth, &body)?;
            match mailbox.list_for_peer(&session.username) {
                Ok(chats) => write_json_response(&mut stream, 200, json!({"chats": chats})).await,
                Err(error) => {
                    write_json_response(&mut stream, 400, json!({"error": error.to_string()})).await
                }
            }
        }
        ("POST", "/api/groups/conference/start") => {
            let body = read_json_body(&mut stream, request).await?;
            let session = session_from_body(auth, &body)?;
            let group_id = body
                .get("groupId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            match conferences.start(&session.username, group_id) {
                Ok(conference) => write_json_response(&mut stream, 200, json!(conference)).await,
                Err(error) => {
                    write_json_response(&mut stream, 400, json!({"error": error.to_string()})).await
                }
            }
        }
        ("POST", "/api/groups/conference/status") => {
            let body = read_json_body(&mut stream, request).await?;
            let session = session_from_body(auth, &body)?;
            let group_id = body
                .get("groupId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            match conferences.status(&session.username, group_id) {
                Ok(conference) => {
                    write_json_response(&mut stream, 200, json!({"conference": conference})).await
                }
                Err(error) => {
                    write_json_response(&mut stream, 400, json!({"error": error.to_string()})).await
                }
            }
        }
        ("POST", "/api/groups/conference/end") => {
            let body = read_json_body(&mut stream, request).await?;
            let session = session_from_body(auth, &body)?;
            let group_id = body
                .get("groupId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            match conferences.end(&session.username, group_id) {
                Ok(()) => write_json_response(&mut stream, 200, json!({"ok": true})).await,
                Err(error) => {
                    write_json_response(&mut stream, 400, json!({"error": error.to_string()})).await
                }
            }
        }
        ("POST", "/api/groups/sfu/join") => {
            let body = read_json_body(&mut stream, request).await?;
            let session = session_from_body(auth, &body)?;
            let request = serde_json::from_value::<sfu::SfuJoinRequest>(body).map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidInput, "sfu join request is invalid")
            })?;
            if !groups.is_member(&session.username, &request.group_id)? {
                write_json_response(
                    &mut stream,
                    401,
                    json!({"error": "user is not a member of this group"}),
                )
                .await?;
                return Ok(());
            }
            let role = sfu::SfuRole::parse(request.role.as_deref())?;
            match sfu
                .join(&request.group_id, &session.username, role, request.offer)
                .await
            {
                Ok(answer) => write_json_response(&mut stream, 200, json!(answer)).await,
                Err(error) => {
                    write_json_response(&mut stream, 400, json!({"error": error.to_string()})).await
                }
            }
        }
        ("POST", "/api/groups/sfu/leave") => {
            let body = read_json_body(&mut stream, request).await?;
            let session = session_from_body(auth, &body)?;
            let group_id = body
                .get("groupId")
                .and_then(Value::as_str)
                .unwrap_or_default();
            if let Some(role) = body
                .get("role")
                .and_then(Value::as_str)
                .filter(|role| !role.is_empty())
            {
                let role = sfu::SfuRole::parse(Some(role))?;
                sfu.leave_role(group_id, &session.username, role).await;
            } else {
                sfu.leave(group_id, &session.username).await;
            }
            write_json_response(&mut stream, 200, json!({"ok": true})).await
        }
        _ => write_json_response(&mut stream, 404, json!({"error": "not found"})).await,
    }
}

fn session_from_body(auth: &AuthStore, body: &Value) -> io::Result<auth::AuthSession> {
    let token = body
        .get("token")
        .and_then(Value::as_str)
        .unwrap_or_default();
    auth.session(token)?
        .ok_or_else(|| io::Error::new(io::ErrorKind::PermissionDenied, "auth token is invalid"))
}

fn authenticated_route(
    request: &str,
    auth: &AuthStore,
    groups: &GroupStore,
) -> io::Result<Option<(String, String)>> {
    let Some(token) = query_param(request, "token") else {
        return Ok(None);
    };
    let session = auth
        .session(&token)?
        .ok_or_else(|| io::Error::new(io::ErrorKind::PermissionDenied, "auth token is invalid"))?;

    if query_param(request, "watch").as_deref() == Some("1") {
        return Ok(Some((
            format!("notify:{}", session.username),
            session.username,
        )));
    }

    if let Some(group_id) = query_param(request, "group") {
        if !groups.is_member(&session.username, &group_id)? {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "user is not a member of this group",
            ));
        }

        return Ok(Some((format!("group:{group_id}"), session.username)));
    }

    let Some(contact) = query_param(request, "contact") else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "contact username is required",
        ));
    };

    let contact = normalize_username(&contact)?;
    if !auth.user_exists(&contact)? {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "contact username does not exist",
        ));
    }

    Ok(Some((
        direct_room(&session.username, &contact),
        session.username,
    )))
}

fn direct_room(first: &str, second: &str) -> String {
    if first <= second {
        format!("dm:{first}:{second}")
    } else {
        format!("dm:{second}:{first}")
    }
}

fn is_websocket_request(request: &str) -> bool {
    header_value(request, "upgrade").is_some_and(|value| value.eq_ignore_ascii_case("websocket"))
}

async fn read_json_body(stream: &mut TcpStream, request: &str) -> io::Result<Value> {
    let length = header_value(request, "content-length")
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(0);
    if length > 64 * 1024 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "request body too large",
        ));
    }

    let mut body = vec![0_u8; length];
    if length > 0 {
        stream.read_exact(&mut body).await?;
    }
    serde_json::from_slice(&body)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "request body is not json"))
}

async fn write_empty_response(stream: &mut TcpStream, status: u16) -> io::Result<()> {
    let response = format!(
        "HTTP/1.1 {status} {}\r\n{}\r\n",
        status_text(status),
        cors_headers()
    );
    stream.write_all(response.as_bytes()).await
}

async fn write_json_response(stream: &mut TcpStream, status: u16, body: Value) -> io::Result<()> {
    let body = body.to_string();
    let response = format!(
        "HTTP/1.1 {status} {}\r\n{}Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{}",
        status_text(status),
        cors_headers(),
        body.len(),
        body
    );
    stream.write_all(response.as_bytes()).await
}

fn cors_headers() -> &'static str {
    "Access-Control-Allow-Origin: *\r\n\
     Access-Control-Allow-Methods: POST, OPTIONS\r\n\
     Access-Control-Allow-Headers: content-type, authorization\r\n"
}

fn status_text(status: u16) -> &'static str {
    match status {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        _ => "Error",
    }
}

async fn read_loop(
    mut reader: OwnedReadHalf,
    rooms: Rooms,
    mailbox: MailboxStore,
    room: String,
    peer: String,
) -> io::Result<()> {
    while let Some(message) = read_text_frame(&mut reader).await? {
        if store_message(&mailbox, &rooms, &room, &peer, &message).await {
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

async fn store_message(
    mailbox: &MailboxStore,
    rooms: &Rooms,
    room: &str,
    peer: &str,
    raw: &str,
) -> bool {
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
        Ok(()) => {
            println!("stored encrypted payload from {peer} in room {room}");
            if let Some(recipient) = mailbox_recipient(room, peer) {
                notify_mailbox_ready(rooms, recipient, room, peer).await;
            }
        }
        Err(error) => eprintln!("failed to persist encrypted mailbox payload: {error}"),
    }
    true
}

fn mailbox_recipient<'a>(room: &'a str, sender: &str) -> Option<&'a str> {
    let mut parts = room.split(':');
    if parts.next()? != "dm" {
        return None;
    }
    let first = parts.next()?;
    let second = parts.next()?;
    if parts.next().is_some() {
        return None;
    }
    if first == sender {
        Some(second)
    } else if second == sender {
        Some(first)
    } else {
        None
    }
}

async fn notify_mailbox_ready(rooms: &Rooms, recipient: &str, room: &str, sender: &str) {
    let listeners = {
        let rooms = rooms.lock().await;
        rooms
            .get(&format!("notify:{recipient}"))
            .map(|peers| peers.values().cloned().collect::<Vec<_>>())
            .unwrap_or_default()
    };
    let event = json!({
        "type": "mailbox-ready",
        "room": room,
        "from": sender,
    })
    .to_string();
    for listener in listeners {
        let _ = listener.send(event.clone());
    }
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
