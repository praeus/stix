//! Engine-agnostic WebRTC core.
//!
//! Godot runs game logic on a single thread and expects synchronous calls, while
//! `webrtc` is fully async. This module bridges the two:
//!
//! * One shared tokio runtime runs every connection's async work.
//! * Each [`PeerHandle`] owns a command queue processed *in order* by a worker
//!   task (so e.g. `add_ice_candidate` can never race ahead of
//!   `set_remote_description`).
//! * Everything coming back from the network is pushed onto plain
//!   `std::sync::mpsc` queues that the Godot side drains once per frame.
//!
//! Nothing in here touches Godot types, so it can be unit-tested on its own.

use std::sync::mpsc;
use std::sync::{Arc, OnceLock};

use bytes::BytesMut;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use webrtc::data_channel::{DataChannel, DataChannelEvent, RTCDataChannelInit, RTCDataChannelState};
use webrtc::peer_connection::{
    PeerConnection, PeerConnectionBuilder, PeerConnectionEventHandler, RTCConfigurationBuilder,
    RTCIceCandidateInit, RTCIceServer, RTCPeerConnectionIceEvent, RTCPeerConnectionState,
    RTCSessionDescription,
};

// ---------------------------------------------------------------------------
// Runtime
// ---------------------------------------------------------------------------

/// Process-wide tokio runtime. Created lazily on first use and kept for the
/// lifetime of the extension.
pub fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("webrtc-sync")
            .enable_all()
            .build()
            .expect("failed to start tokio runtime")
    })
}

// ---------------------------------------------------------------------------
// Events (network -> game thread)
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub enum PeerEvent {
    /// A local offer/answer is ready and must be sent to the remote peer.
    LocalDescription { sdp_type: String, sdp: String },
    /// A local ICE candidate was gathered and must be sent to the remote peer.
    IceCandidate {
        candidate: String,
        sdp_mid: String,
        sdp_mline_index: i64,
    },
    ConnectionState(ConnectionState),
    /// The remote side opened a data channel.
    DataChannel(ChannelHandle),
    Error(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectionState {
    New,
    Connecting,
    Connected,
    Disconnected,
    Failed,
    Closed,
}

impl ConnectionState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::New => "new",
            Self::Connecting => "connecting",
            Self::Connected => "connected",
            Self::Disconnected => "disconnected",
            Self::Failed => "failed",
            Self::Closed => "closed",
        }
    }

    fn from_rtc(state: RTCPeerConnectionState) -> Self {
        match state {
            RTCPeerConnectionState::Connecting => Self::Connecting,
            RTCPeerConnectionState::Connected => Self::Connected,
            RTCPeerConnectionState::Disconnected => Self::Disconnected,
            RTCPeerConnectionState::Failed => Self::Failed,
            RTCPeerConnectionState::Closed => Self::Closed,
            _ => Self::New,
        }
    }
}

#[derive(Debug)]
pub enum ChannelEvent {
    Open,
    Closed,
    Message { data: Vec<u8>, is_string: bool },
    Error(String),
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default)]
pub struct IceServer {
    pub urls: Vec<String>,
    pub username: String,
    pub credential: String,
}

#[derive(Debug, Clone, Copy)]
pub struct ChannelOptions {
    pub ordered: bool,
    /// `None` = fully reliable. `Some(0)` = fire-and-forget.
    pub max_retransmits: Option<u16>,
    pub max_packet_life_time: Option<u16>,
}

impl ChannelOptions {
    pub const RELIABLE: Self = Self {
        ordered: true,
        max_retransmits: None,
        max_packet_life_time: None,
    };
    pub const UNRELIABLE: Self = Self {
        ordered: false,
        max_retransmits: Some(0),
        max_packet_life_time: None,
    };
}

// ---------------------------------------------------------------------------
// Data channel
// ---------------------------------------------------------------------------

enum Outgoing {
    Binary(Vec<u8>),
    Text(String),
    Close,
}

/// Game-thread side of a data channel.
#[derive(Debug)]
pub struct ChannelHandle {
    label: String,
    options: ChannelOptions,
    out_tx: UnboundedSender<Outgoing>,
    ev_rx: mpsc::Receiver<ChannelEvent>,
    open: bool,
}

impl std::fmt::Debug for Outgoing {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Outgoing")
    }
}

/// Network side of a data channel, handed to the task that drives it.
struct ChannelBackend {
    out_rx: UnboundedReceiver<Outgoing>,
    ev_tx: mpsc::Sender<ChannelEvent>,
}

fn channel_pair(label: String, options: ChannelOptions) -> (ChannelHandle, ChannelBackend) {
    let (out_tx, out_rx) = unbounded_channel();
    let (ev_tx, ev_rx) = mpsc::channel();
    (
        ChannelHandle {
            label,
            options,
            out_tx,
            ev_rx,
            open: false,
        },
        ChannelBackend { out_rx, ev_tx },
    )
}

impl ChannelHandle {
    pub fn label(&self) -> &str {
        &self.label
    }

    pub fn options(&self) -> ChannelOptions {
        self.options
    }

    pub fn is_open(&self) -> bool {
        self.open
    }

    /// Queue binary data. Messages sent before the channel opens are held
    /// until it does.
    pub fn send(&self, data: Vec<u8>) -> bool {
        self.out_tx.send(Outgoing::Binary(data)).is_ok()
    }

    pub fn send_text(&self, text: String) -> bool {
        self.out_tx.send(Outgoing::Text(text)).is_ok()
    }

    pub fn close(&self) {
        let _ = self.out_tx.send(Outgoing::Close);
    }

    /// Drain all pending events. Call once per frame.
    pub fn drain(&mut self) -> Vec<ChannelEvent> {
        let events: Vec<_> = self.ev_rx.try_iter().collect();
        for ev in &events {
            match ev {
                ChannelEvent::Open => self.open = true,
                ChannelEvent::Closed => self.open = false,
                _ => {}
            }
        }
        events
    }
}

async fn run_channel(dc: Arc<dyn DataChannel>, mut backend: ChannelBackend) {
    let ev_tx = backend.ev_tx;
    let mut opened = matches!(dc.ready_state().await, Ok(RTCDataChannelState::Open));
    if opened {
        let _ = ev_tx.send(ChannelEvent::Open);
    }

    loop {
        tokio::select! {
            event = dc.poll() => match event {
                Some(DataChannelEvent::OnOpen) => {
                    if !opened {
                        opened = true;
                        let _ = ev_tx.send(ChannelEvent::Open);
                    }
                }
                Some(DataChannelEvent::OnMessage(msg)) => {
                    let _ = ev_tx.send(ChannelEvent::Message {
                        data: msg.data.to_vec(),
                        is_string: msg.is_string,
                    });
                }
                Some(DataChannelEvent::OnError) => {
                    let _ = ev_tx.send(ChannelEvent::Error("data channel error".into()));
                }
                Some(DataChannelEvent::OnClose) | None => break,
                Some(_) => {}
            },
            // Only pull outgoing messages once open, so early sends are buffered.
            out = backend.out_rx.recv(), if opened => {
                let result = match out {
                    Some(Outgoing::Binary(data)) => dc.send(BytesMut::from(&data[..])).await,
                    Some(Outgoing::Text(text)) => dc.send_text(&text).await,
                    Some(Outgoing::Close) | None => {
                        let _ = dc.close().await;
                        break;
                    }
                };
                if let Err(e) = result {
                    let _ = ev_tx.send(ChannelEvent::Error(e.to_string()));
                }
            }
        }
    }

    let _ = ev_tx.send(ChannelEvent::Closed);
}

fn spawn_channel(dc: Arc<dyn DataChannel>, backend: ChannelBackend) {
    runtime().spawn(run_channel(dc, backend));
}

// ---------------------------------------------------------------------------
// Peer connection
// ---------------------------------------------------------------------------

enum Command {
    CreateOffer,
    SetRemoteDescription { sdp_type: String, sdp: String },
    AddIceCandidate(RTCIceCandidateInit),
    CreateDataChannel {
        options: ChannelOptions,
        label: String,
        backend: ChannelBackend,
    },
    Close,
}

/// Game-thread side of a peer connection.
pub struct PeerHandle {
    cmd_tx: UnboundedSender<Command>,
    ev_rx: mpsc::Receiver<PeerEvent>,
    state: ConnectionState,
}

#[derive(Clone)]
struct Handler {
    ev_tx: mpsc::Sender<PeerEvent>,
}

#[async_trait::async_trait]
impl PeerConnectionEventHandler for Handler {
    async fn on_ice_candidate(&self, event: RTCPeerConnectionIceEvent) {
        match event.candidate.to_json() {
            Ok(init) => {
                let _ = self.ev_tx.send(PeerEvent::IceCandidate {
                    candidate: init.candidate,
                    sdp_mid: init.sdp_mid.unwrap_or_default(),
                    sdp_mline_index: init.sdp_mline_index.map_or(0, i64::from),
                });
            }
            Err(e) => {
                let _ = self.ev_tx.send(PeerEvent::Error(format!("ice candidate: {e}")));
            }
        }
    }

    async fn on_connection_state_change(&self, state: RTCPeerConnectionState) {
        let _ = self
            .ev_tx
            .send(PeerEvent::ConnectionState(ConnectionState::from_rtc(state)));
    }

    async fn on_data_channel(&self, dc: Arc<dyn DataChannel>) {
        let label = dc.label().await.unwrap_or_default();
        let options = ChannelOptions {
            ordered: dc.ordered().await.unwrap_or(true),
            max_retransmits: dc.max_retransmits().await.ok().flatten(),
            max_packet_life_time: dc.max_packet_life_time().await.ok().flatten(),
        };
        let (handle, backend) = channel_pair(label, options);
        spawn_channel(dc, backend);
        let _ = self.ev_tx.send(PeerEvent::DataChannel(handle));
    }
}

impl PeerHandle {
    /// Build a peer connection. Blocks briefly while local sockets are bound.
    pub fn new(ice_servers: Vec<IceServer>) -> Result<Self, String> {
        let (ev_tx, ev_rx) = mpsc::channel();
        let (cmd_tx, cmd_rx) = unbounded_channel();

        let config = RTCConfigurationBuilder::new()
            .with_ice_servers(
                ice_servers
                    .into_iter()
                    .map(|s| RTCIceServer {
                        urls: s.urls,
                        username: s.username,
                        credential: s.credential,
                    })
                    .collect(),
            )
            .build();

        let handler = Handler {
            ev_tx: ev_tx.clone(),
        };
        let pc = runtime()
            .block_on(
                PeerConnectionBuilder::new()
                    .with_configuration(config)
                    .with_handler(Arc::new(handler))
                    .with_udp_addrs(vec!["0.0.0.0:0".to_string()])
                    .build(),
            )
            .map_err(|e| e.to_string())?;

        runtime().spawn(run_peer(Arc::new(pc), cmd_rx, ev_tx));

        Ok(Self {
            cmd_tx,
            ev_rx,
            state: ConnectionState::New,
        })
    }

    pub fn state(&self) -> ConnectionState {
        self.state
    }

    /// Start negotiation as the offering side. Emits `LocalDescription`.
    pub fn create_offer(&self) {
        let _ = self.cmd_tx.send(Command::CreateOffer);
    }

    /// Apply a remote offer/answer. If it is an offer, an answer is created
    /// automatically and emitted as `LocalDescription`.
    pub fn set_remote_description(&self, sdp_type: String, sdp: String) {
        let _ = self
            .cmd_tx
            .send(Command::SetRemoteDescription { sdp_type, sdp });
    }

    pub fn add_ice_candidate(&self, candidate: String, sdp_mid: String, sdp_mline_index: i64) {
        let init = RTCIceCandidateInit {
            candidate,
            sdp_mid: (!sdp_mid.is_empty()).then_some(sdp_mid),
            sdp_mline_index: u16::try_from(sdp_mline_index).ok(),
            ..Default::default()
        };
        let _ = self.cmd_tx.send(Command::AddIceCandidate(init));
    }

    /// Create a data channel. Must be called *before* `create_offer` on the
    /// offering side so that it is part of the initial negotiation.
    pub fn create_data_channel(&self, label: &str, options: ChannelOptions) -> ChannelHandle {
        let (handle, backend) = channel_pair(label.to_string(), options);
        let _ = self.cmd_tx.send(Command::CreateDataChannel {
            options,
            label: label.to_string(),
            backend,
        });
        handle
    }

    pub fn close(&self) {
        let _ = self.cmd_tx.send(Command::Close);
    }

    pub fn drain(&mut self) -> Vec<PeerEvent> {
        let events: Vec<_> = self.ev_rx.try_iter().collect();
        for ev in &events {
            if let PeerEvent::ConnectionState(s) = ev {
                self.state = *s;
            }
        }
        events
    }
}

impl Drop for PeerHandle {
    fn drop(&mut self) {
        self.close();
    }
}

async fn run_peer(
    pc: Arc<dyn PeerConnection>,
    mut cmd_rx: UnboundedReceiver<Command>,
    ev_tx: mpsc::Sender<PeerEvent>,
) {
    let report = |result: Result<(), String>| {
        if let Err(e) = result {
            let _ = ev_tx.send(PeerEvent::Error(e));
        }
    };

    while let Some(cmd) = cmd_rx.recv().await {
        match cmd {
            Command::CreateOffer => report(
                async {
                    let offer = pc.create_offer(None).await.map_err(|e| e.to_string())?;
                    let sdp = offer.sdp.clone();
                    pc.set_local_description(offer)
                        .await
                        .map_err(|e| e.to_string())?;
                    let _ = ev_tx.send(PeerEvent::LocalDescription {
                        sdp_type: "offer".into(),
                        sdp,
                    });
                    Ok(())
                }
                .await,
            ),
            Command::SetRemoteDescription { sdp_type, sdp } => report(
                async {
                    let desc = match sdp_type.as_str() {
                        "offer" => RTCSessionDescription::offer(sdp),
                        "answer" => RTCSessionDescription::answer(sdp),
                        "pranswer" => RTCSessionDescription::pranswer(sdp),
                        other => return Err(format!("unknown sdp type '{other}'")),
                    }
                    .map_err(|e| e.to_string())?;
                    pc.set_remote_description(desc)
                        .await
                        .map_err(|e| e.to_string())?;

                    if sdp_type == "offer" {
                        let answer = pc.create_answer(None).await.map_err(|e| e.to_string())?;
                        let sdp = answer.sdp.clone();
                        pc.set_local_description(answer)
                            .await
                            .map_err(|e| e.to_string())?;
                        let _ = ev_tx.send(PeerEvent::LocalDescription {
                            sdp_type: "answer".into(),
                            sdp,
                        });
                    }
                    Ok(())
                }
                .await,
            ),
            Command::AddIceCandidate(init) => {
                report(pc.add_ice_candidate(init).await.map_err(|e| e.to_string()))
            }
            Command::CreateDataChannel {
                options,
                label,
                backend,
            } => {
                let init = RTCDataChannelInit {
                    ordered: options.ordered,
                    max_retransmits: options.max_retransmits,
                    max_packet_life_time: options.max_packet_life_time,
                    ..Default::default()
                };
                match pc.create_data_channel(&label, Some(init)).await {
                    Ok(dc) => spawn_channel(dc, backend),
                    Err(e) => {
                        let _ = backend.ev_tx.send(ChannelEvent::Error(e.to_string()));
                        let _ = backend.ev_tx.send(ChannelEvent::Closed);
                    }
                }
            }
            Command::Close => break,
        }
    }

    // Reached on explicit close or when the PeerHandle is dropped.
    let _ = pc.close().await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    /// Shuttle signaling between two handles until `done` returns true.
    fn pump(a: &mut PeerHandle, b: &mut PeerHandle, mut done: impl FnMut(&mut PeerHandle, &mut PeerHandle) -> bool) {
        let deadline = Instant::now() + Duration::from_secs(15);
        while Instant::now() < deadline {
            for ev in a.drain() {
                forward(ev, b);
            }
            for ev in b.drain() {
                forward(ev, a);
            }
            if done(a, b) {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("timed out");
    }

    fn forward(ev: PeerEvent, to: &PeerHandle) {
        match ev {
            PeerEvent::LocalDescription { sdp_type, sdp } => to.set_remote_description(sdp_type, sdp),
            PeerEvent::IceCandidate { candidate, sdp_mid, sdp_mline_index } => {
                to.add_ice_candidate(candidate, sdp_mid, sdp_mline_index)
            }
            PeerEvent::DataChannel(chan) => REMOTE.with(|r| *r.borrow_mut() = Some(chan)),
            PeerEvent::Error(e) => panic!("peer error: {e}"),
            PeerEvent::ConnectionState(_) => {}
        }
    }

    thread_local! {
        static REMOTE: std::cell::RefCell<Option<ChannelHandle>> = const { std::cell::RefCell::new(None) };
    }

    #[test]
    fn two_peers_exchange_messages() {
        let mut a = PeerHandle::new(Vec::new()).unwrap();
        let mut b = PeerHandle::new(Vec::new()).unwrap();
        let mut local = a.create_data_channel("test", ChannelOptions::RELIABLE);
        // Queued before open: must still be delivered.
        local.send(b"hello".to_vec());
        a.create_offer();

        let mut received = Vec::new();
        pump(&mut a, &mut b, |_, _| {
            local.drain();
            REMOTE.with(|r| {
                if let Some(chan) = r.borrow_mut().as_mut() {
                    for ev in chan.drain() {
                        if let ChannelEvent::Message { data, .. } = ev {
                            received.push(data);
                        }
                    }
                }
            });
            !received.is_empty()
        });

        assert_eq!(received[0], b"hello");
        assert_eq!(a.state(), ConnectionState::Connected);
    }
}
