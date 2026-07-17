use std::io;

use base64::{Engine as _, engine::general_purpose};
use sha1::{Digest, Sha1};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{
        TcpStream,
        tcp::{OwnedReadHalf, OwnedWriteHalf},
    },
};

const WEBSOCKET_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub async fn read_http_request(stream: &mut TcpStream) -> io::Result<String> {
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

pub fn header_value(request: &str, name: &str) -> Option<String> {
    request.lines().find_map(|line| {
        let (key, value) = line.split_once(':')?;
        key.eq_ignore_ascii_case(name)
            .then(|| value.trim().to_string())
    })
}

pub fn request_method(request: &str) -> &str {
    request
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().next())
        .unwrap_or_default()
}

pub fn request_path(request: &str) -> &str {
    request
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .unwrap_or("/")
}

pub fn parse_query(request: &str) -> (String, String) {
    let path = request_path(request);

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

pub fn query_param(request: &str, name: &str) -> Option<String> {
    let path = request_path(request);
    let query = path
        .split_once('?')
        .map(|(_, query)| query)
        .unwrap_or_default();

    query.split('&').find_map(|part| {
        let (key, value) = part.split_once('=')?;
        (key == name && !value.is_empty()).then(|| percent_decode(value))
    })
}

pub fn websocket_accept_key(key: &str) -> String {
    let mut hasher = Sha1::new();
    hasher.update(key.as_bytes());
    hasher.update(WEBSOCKET_GUID.as_bytes());
    general_purpose::STANDARD.encode(hasher.finalize())
}

pub async fn read_text_frame(reader: &mut OwnedReadHalf) -> io::Result<Option<String>> {
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

pub async fn write_text_frame(writer: &mut OwnedWriteHalf, message: &str) -> io::Result<()> {
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
