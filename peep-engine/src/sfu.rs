use std::{collections::HashMap, io, sync::Arc};

use serde::{Deserialize, Serialize};
use tokio::{
    sync::{Mutex, mpsc, watch},
    time::{Duration, Instant},
};
use webrtc::{
    api::{API, APIBuilder, media_engine::MediaEngine},
    ice_transport::ice_server::RTCIceServer,
    interceptor::registry::Registry,
    peer_connection::{
        RTCPeerConnection, configuration::RTCConfiguration,
        sdp::session_description::RTCSessionDescription,
    },
    rtcp::{packet::Packet, payload_feedbacks::picture_loss_indication::PictureLossIndication},
    rtp_transceiver::rtp_codec::RTCRtpCodecCapability,
    rtp_transceiver::{rtp_receiver::RTCRtpReceiver, rtp_sender::RTCRtpSender},
    track::track_local::{
        TrackLocal, TrackLocalWriter, track_local_static_rtp::TrackLocalStaticRTP,
    },
};

const KEYFRAME_REQUEST_COOLDOWN: Duration = Duration::from_millis(500);
const INITIAL_KEYFRAME_RETRIES: [Duration; 4] = [
    Duration::ZERO,
    Duration::from_millis(250),
    Duration::from_millis(500),
    Duration::from_millis(750),
];

#[derive(Clone)]
pub struct SfuServer {
    api: Arc<API>,
    rooms: Arc<Mutex<HashMap<String, SfuRoom>>>,
    track_ready: mpsc::UnboundedSender<(String, String)>,
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
    source_connection: Arc<RTCPeerConnection>,
    source_ssrc: u32,
    is_video: bool,
    last_keyframe_request: Mutex<Option<Instant>>,
    cancel: watch::Sender<bool>,
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
    pub fn new(track_ready: mpsc::UnboundedSender<(String, String)>) -> io::Result<Self> {
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
            track_ready,
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
                for track in room.tracks.iter().filter(|track| track.owner == username) {
                    let _ = track.cancel.send(true);
                }
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
                        .map(Arc::clone)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default()
        };

        for track in tracks {
            let sender = connection
                .add_track(Arc::clone(&track.track) as Arc<dyn TrackLocal + Send + Sync>)
                .await
                .map_err(to_io_error)?;
            spawn_sender_rtcp_forwarder(sender, Arc::clone(&track));

            if track.is_video {
                let track = Arc::clone(&track);
                tokio::spawn(async move {
                    for delay in INITIAL_KEYFRAME_RETRIES {
                        if !delay.is_zero() {
                            tokio::time::sleep(delay).await;
                        }
                        if *track.cancel.borrow() {
                            break;
                        }
                        let _ = request_keyframe(&track).await;
                    }
                });
            }
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
        let publisher_connection = Arc::downgrade(connection);
        let track_ready = self.track_ready.clone();
        connection.on_track(Box::new(move |remote_track, receiver, _| {
            let rooms = Arc::clone(&rooms);
            let group_id = group_id.clone();
            let username = username.clone();
            let publisher_connection = publisher_connection.clone();
            let track_ready = track_ready.clone();

            Box::pin(async move {
                let Some(source_connection) = publisher_connection.upgrade() else {
                    return;
                };
                let codec = remote_track.codec();
                let is_video = codec.capability.mime_type.starts_with("video/");
                let source_ssrc = remote_track.ssrc();
                let (cancel, cancelled) = watch::channel(false);
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
                        source_connection: Arc::clone(&source_connection),
                        source_ssrc,
                        is_video,
                        last_keyframe_request: Mutex::new(None),
                        cancel,
                    }));
                }

                // A paused or low-frame-rate publisher may not send its first
                // video packet until after the client's conference refresh.
                // Notify subscribers only once the forwarded track exists.
                let _ = track_ready.send((group_id.clone(), username.clone()));

                spawn_receiver_rtcp_drain(receiver, cancelled.clone());

                tokio::spawn(async move {
                    let mut cancelled = cancelled;
                    loop {
                        tokio::select! {
                            packet = remote_track.read_rtp() => {
                                let Ok((packet, _)) = packet else { break; };
                                let _ = local_track.write_rtp(&packet).await;
                            }
                            changed = cancelled.changed() => {
                                if changed.is_err() || *cancelled.borrow() { break; }
                            }
                        }
                    }
                });
            })
        }));
    }
}

fn spawn_receiver_rtcp_drain(receiver: Arc<RTCRtpReceiver>, mut cancelled: watch::Receiver<bool>) {
    tokio::spawn(async move {
        loop {
            if *cancelled.borrow() {
                break;
            }
            tokio::select! {
                result = receiver.read_rtcp() => {
                    if result.is_err() { break; }
                }
                changed = cancelled.changed() => {
                    if changed.is_err() || *cancelled.borrow() { break; }
                }
            }
        }
    });
}

fn spawn_sender_rtcp_forwarder(sender: Arc<RTCRtpSender>, forwarded_track: Arc<SfuForwardedTrack>) {
    let mut cancelled = forwarded_track.cancel.subscribe();
    tokio::spawn(async move {
        loop {
            if *cancelled.borrow() {
                break;
            }
            let result = tokio::select! {
                result = sender.read_rtcp() => result,
                _ = cancelled.changed() => break,
            };
            let Ok((packets, _)) = result else {
                break;
            };
            if forwarded_track.is_video {
                if let Some(packet) = packets.iter().find_map(|packet| {
                    upstream_pli_for_feedback(packet.as_ref(), forwarded_track.source_ssrc)
                }) {
                    let _ = request_keyframe_with_packet(&forwarded_track, packet).await;
                }
            }
        }
    });
}

async fn request_keyframe(track: &SfuForwardedTrack) -> bool {
    if !track.is_video {
        return false;
    }
    request_keyframe_with_packet(track, upstream_picture_loss_indication(track.source_ssrc)).await
}

async fn request_keyframe_with_packet(
    track: &SfuForwardedTrack,
    packet: Box<dyn Packet + Send + Sync>,
) -> bool {
    let requested_at = Instant::now();
    {
        let mut last_request = track.last_keyframe_request.lock().await;
        if last_request.is_some_and(|last| {
            requested_at.saturating_duration_since(last) < KEYFRAME_REQUEST_COOLDOWN
        }) {
            return false;
        }
        *last_request = Some(requested_at);
    }

    if *track.cancel.borrow() {
        return false;
    }
    let sent =
        matches!(track.source_connection.write_rtcp(&[packet]).await, Ok(bytes) if bytes > 0);
    if !sent {
        let mut last_request = track.last_keyframe_request.lock().await;
        if *last_request == Some(requested_at) {
            *last_request = None;
        }
    }
    sent
}

fn upstream_picture_loss_indication(media_ssrc: u32) -> Box<dyn Packet + Send + Sync> {
    Box::new(PictureLossIndication {
        sender_ssrc: 0,
        media_ssrc,
    })
}

fn upstream_pli_for_feedback(
    packet: &(dyn Packet + Send + Sync),
    source_ssrc: u32,
) -> Option<Box<dyn Packet + Send + Sync>> {
    is_picture_loss_indication(packet).then(|| upstream_picture_loss_indication(source_ssrc))
}

fn is_picture_loss_indication(packet: &(dyn Packet + Send + Sync)) -> bool {
    packet
        .as_any()
        .downcast_ref::<PictureLossIndication>()
        .is_some()
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
