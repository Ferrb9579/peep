use std::{collections::HashMap, io, sync::Arc};

use serde::{Deserialize, Serialize};
use tokio::sync::Mutex;
use webrtc::{
    api::{API, APIBuilder, media_engine::MediaEngine},
    ice_transport::ice_server::RTCIceServer,
    interceptor::registry::Registry,
    peer_connection::{
        RTCPeerConnection, configuration::RTCConfiguration,
        sdp::session_description::RTCSessionDescription,
    },
    rtp_transceiver::rtp_codec::RTCRtpCodecCapability,
    track::track_local::{
        TrackLocal, TrackLocalWriter, track_local_static_rtp::TrackLocalStaticRTP,
    },
};

#[derive(Clone)]
pub struct SfuServer {
    api: Arc<API>,
    rooms: Arc<Mutex<HashMap<String, SfuRoom>>>,
}

#[derive(Default)]
struct SfuRoom {
    peers: HashMap<String, Arc<SfuPeer>>,
    tracks: Vec<Arc<SfuForwardedTrack>>,
}

struct SfuPeer {
    connection: Arc<RTCPeerConnection>,
    owner: String,
    role: SfuRole,
}

struct SfuForwardedTrack {
    owner: String,
    track: Arc<TrackLocalStaticRTP>,
}

#[derive(Debug, Deserialize)]
pub struct SfuJoinRequest {
    #[serde(rename = "groupId")]
    pub group_id: String,
    pub role: Option<String>,
    pub offer: RTCSessionDescription,
}

#[derive(Debug, Serialize)]
pub struct SfuJoinResponse {
    pub answer: RTCSessionDescription,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SfuRole {
    Publisher,
    Subscriber,
    PublishSubscribe,
}

impl SfuServer {
    pub fn new() -> io::Result<Self> {
        let mut media_engine = MediaEngine::default();
        media_engine
            .register_default_codecs()
            .map_err(to_io_error)?;
        let registry = Registry::new();
        let api = APIBuilder::new()
            .with_media_engine(media_engine)
            .with_interceptor_registry(registry)
            .build();

        Ok(Self {
            api: Arc::new(api),
            rooms: Arc::new(Mutex::new(HashMap::new())),
        })
    }

    pub async fn join(
        &self,
        group_id: &str,
        username: &str,
        role: SfuRole,
        offer: RTCSessionDescription,
    ) -> io::Result<SfuJoinResponse> {
        self.leave_role(group_id, username, role).await;

        let connection = Arc::new(
            self.api
                .new_peer_connection(RTCConfiguration {
                    ice_servers: vec![RTCIceServer {
                        urls: vec!["stun:stun.l.google.com:19302".to_string()],
                        ..Default::default()
                    }],
                    ..Default::default()
                })
                .await
                .map_err(to_io_error)?,
        );

        if role.subscribes() {
            self.add_existing_tracks(group_id, username, &connection)
                .await?;
        }
        if role.publishes() {
            self.wire_incoming_tracks(group_id.to_string(), username.to_string(), &connection);
        }

        connection
            .set_remote_description(offer)
            .await
            .map_err(to_io_error)?;
        let mut gather_complete = connection.gathering_complete_promise().await;
        let answer = connection.create_answer(None).await.map_err(to_io_error)?;
        connection
            .set_local_description(answer)
            .await
            .map_err(to_io_error)?;
        let _ = gather_complete.recv().await;
        let answer = connection
            .local_description()
            .await
            .ok_or_else(|| io::Error::other("SFU answer was not generated"))?;

        {
            let mut rooms = self.rooms.lock().await;
            let room = rooms.entry(group_id.to_string()).or_default();
            room.peers.insert(
                peer_key(username, role),
                Arc::new(SfuPeer {
                    connection,
                    owner: username.to_string(),
                    role,
                }),
            );
        }

        Ok(SfuJoinResponse { answer })
    }

    pub async fn leave(&self, group_id: &str, username: &str) {
        self.leave_inner(group_id, username, None).await;
    }

    pub async fn leave_role(&self, group_id: &str, username: &str, role: SfuRole) {
        self.leave_inner(group_id, username, Some(role)).await;
    }

    async fn leave_inner(&self, group_id: &str, username: &str, role: Option<SfuRole>) {
        let connections = {
            let mut rooms = self.rooms.lock().await;
            let Some(room) = rooms.get_mut(group_id) else {
                return;
            };

            let removed_keys = room
                .peers
                .iter()
                .filter(|(_, peer)| {
                    peer.owner == username && role.is_none_or(|role| role == peer.role)
                })
                .map(|(key, _)| key.clone())
                .collect::<Vec<_>>();
            let mut connections = Vec::with_capacity(removed_keys.len());
            let remove_published_tracks = role.is_none_or(SfuRole::publishes);
            for key in removed_keys {
                if let Some(peer) = room.peers.remove(&key) {
                    connections.push(Arc::clone(&peer.connection));
                }
            }
            if remove_published_tracks {
                room.tracks.retain(|track| track.owner != username);
            }
            if room.peers.is_empty() && room.tracks.is_empty() {
                rooms.remove(group_id);
            }
            connections
        };

        for connection in connections {
            let _ = connection.close().await;
        }
    }

    async fn add_existing_tracks(
        &self,
        group_id: &str,
        username: &str,
        connection: &Arc<RTCPeerConnection>,
    ) -> io::Result<()> {
        let tracks = {
            let rooms = self.rooms.lock().await;
            rooms
                .get(group_id)
                .map(|room| {
                    room.tracks
                        .iter()
                        .filter(|track| track.owner != username)
                        .map(|track| Arc::clone(&track.track))
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default()
        };

        for track in tracks {
            connection
                .add_track(track as Arc<dyn TrackLocal + Send + Sync>)
                .await
                .map_err(to_io_error)?;
        }
        Ok(())
    }

    fn wire_incoming_tracks(
        &self,
        group_id: String,
        username: String,
        connection: &Arc<RTCPeerConnection>,
    ) {
        let rooms = Arc::clone(&self.rooms);
        connection.on_track(Box::new(move |remote_track, _, _| {
            let rooms = Arc::clone(&rooms);
            let group_id = group_id.clone();
            let username = username.clone();

            Box::pin(async move {
                let codec = remote_track.codec();
                let local_track = Arc::new(TrackLocalStaticRTP::new(
                    RTCRtpCodecCapability {
                        mime_type: codec.capability.mime_type,
                        clock_rate: codec.capability.clock_rate,
                        channels: codec.capability.channels,
                        sdp_fmtp_line: codec.capability.sdp_fmtp_line,
                        rtcp_feedback: codec.capability.rtcp_feedback,
                    },
                    remote_track.id(),
                    format!("sfu-{group_id}-{username}"),
                ));
                {
                    let mut rooms = rooms.lock().await;
                    let room = rooms.entry(group_id.clone()).or_default();
                    room.tracks.push(Arc::new(SfuForwardedTrack {
                        owner: username.clone(),
                        track: Arc::clone(&local_track),
                    }));
                }

                tokio::spawn(async move {
                    while let Ok((packet, _)) = remote_track.read_rtp().await {
                        if local_track.write_rtp(&packet).await.is_err() {
                            break;
                        }
                    }
                });
            })
        }));
    }
}

impl Drop for SfuServer {
    fn drop(&mut self) {
        if Arc::strong_count(&self.rooms) == 1 {
            if let Ok(mut rooms) = self.rooms.try_lock() {
                rooms.clear();
            }
        }
    }
}

fn to_io_error(error: impl std::error::Error + Send + Sync + 'static) -> io::Error {
    io::Error::other(error)
}

impl SfuRole {
    pub fn parse(value: Option<&str>) -> io::Result<Self> {
        match value.unwrap_or("publish-subscribe") {
            "publisher" => Ok(Self::Publisher),
            "subscriber" => Ok(Self::Subscriber),
            "publish-subscribe" => Ok(Self::PublishSubscribe),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "sfu role is invalid",
            )),
        }
    }

    fn publishes(self) -> bool {
        matches!(self, Self::Publisher | Self::PublishSubscribe)
    }

    fn subscribes(self) -> bool {
        matches!(self, Self::Subscriber | Self::PublishSubscribe)
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Publisher => "publisher",
            Self::Subscriber => "subscriber",
            Self::PublishSubscribe => "publish-subscribe",
        }
    }
}

fn peer_key(username: &str, role: SfuRole) -> String {
    format!("{username}:{}", role.as_str())
}
