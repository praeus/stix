//! Low-level GDScript bindings: `RtcPeer` and `RtcChannel`.
//!
//! These mirror the browser WebRTC API closely. Signaling (getting SDP and ICE
//! candidates to the other side) is left to the caller, e.g. via WebSocketPeer.

use godot::classes::{IRefCounted, RefCounted};
use godot::global::Error;
use godot::prelude::*;

use crate::core::{ChannelEvent, ChannelHandle, ChannelOptions, IceServer, PeerEvent, PeerHandle};

// ---------------------------------------------------------------------------
// RtcChannel
// ---------------------------------------------------------------------------

/// A WebRTC data channel. Obtain one from `RtcPeer.create_data_channel()` or the
/// `RtcPeer.data_channel_received` signal. Polled automatically by its peer.
#[derive(GodotClass)]
#[class(no_init, base=RefCounted)]
pub struct RtcChannel {
    handle: ChannelHandle,
    base: Base<RefCounted>,
}

#[godot_api]
impl RtcChannel {
    #[signal]
    fn opened();
    #[signal]
    fn closed();
    #[signal]
    fn message_received(data: PackedByteArray, is_string: bool);
    #[signal]
    fn error(message: GString);

    pub fn from_handle(handle: ChannelHandle) -> Gd<Self> {
        Gd::from_init_fn(|base| Self { handle, base })
    }

    /// Send binary data. Data sent before the channel opens is queued.
    #[func]
    fn send(&self, data: PackedByteArray) -> bool {
        self.handle.send(data.to_vec())
    }

    #[func]
    fn send_text(&self, text: GString) -> bool {
        self.handle.send_text(text.to_string())
    }

    /// Send any Variant (serialized with `var_to_bytes`; Objects are not allowed).
    #[func]
    fn send_var(&self, value: Variant) -> bool {
        self.handle
            .send(godot::global::var_to_bytes(&value).to_vec())
    }

    #[func]
    fn get_label(&self) -> GString {
        self.handle.label().into()
    }

    #[func]
    fn is_ordered(&self) -> bool {
        self.handle.options().ordered
    }

    #[func]
    fn is_open(&self) -> bool {
        self.handle.is_open()
    }

    #[func]
    fn close(&self) {
        self.handle.close();
    }

    /// Emit signals for pending events. `RtcPeer.poll()` calls this for you.
    #[func]
    pub fn poll(&mut self) {
        for event in self.handle.drain() {
            match event {
                ChannelEvent::Open => self.signals().opened().emit(),
                ChannelEvent::Closed => self.signals().closed().emit(),
                ChannelEvent::Message { data, is_string } => self
                    .signals()
                    .message_received()
                    .emit(&PackedByteArray::from(data), is_string),
                ChannelEvent::Error(msg) => self.signals().error().emit(&GString::from(&msg)),
            }
        }
    }
}

// ---------------------------------------------------------------------------
// RtcPeer
// ---------------------------------------------------------------------------

/// A single WebRTC peer connection.
///
/// ```gdscript
/// var peer := RtcPeer.new()
/// peer.initialize({"iceServers": [{"urls": ["stun:stun.l.google.com:19302"]}]})
/// peer.session_description_created.connect(func(type, sdp): signaling.send(...))
/// peer.ice_candidate_created.connect(func(c, mid, idx): signaling.send(...))
/// var chan := peer.create_data_channel("chat")
/// peer.create_offer()
/// # ...then call peer.poll() every frame.
/// ```
#[derive(GodotClass)]
#[class(init, base=RefCounted)]
pub struct RtcPeer {
    handle: Option<PeerHandle>,
    channels: Vec<Gd<RtcChannel>>,
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for RtcPeer {}

#[godot_api]
impl RtcPeer {
    #[signal]
    fn session_description_created(sdp_type: GString, sdp: GString);
    #[signal]
    fn ice_candidate_created(candidate: GString, sdp_mid: GString, sdp_mline_index: i64);
    #[signal]
    fn connection_state_changed(state: GString);
    #[signal]
    fn data_channel_received(channel: Gd<RtcChannel>);
    #[signal]
    fn error(message: GString);

    /// Create the underlying connection. `config` follows the browser shape:
    /// `{"iceServers": [{"urls": [...], "username": "", "credential": ""}]}`.
    #[func]
    fn initialize(&mut self, config: VarDictionary) -> Error {
        match PeerHandle::new(parse_ice_servers(&config)) {
            Ok(handle) => {
                self.handle = Some(handle);
                Error::OK
            }
            Err(e) => {
                godot_error!("RtcPeer.initialize failed: {e}");
                Error::FAILED
            }
        }
    }

    #[func]
    fn create_offer(&self) -> Error {
        self.with_handle(|h| h.create_offer())
    }

    /// Apply the remote description. When `sdp_type` is "offer", an answer is
    /// generated and delivered via `session_description_created`.
    #[func]
    fn set_remote_description(&self, sdp_type: GString, sdp: GString) -> Error {
        self.with_handle(|h| h.set_remote_description(sdp_type.to_string(), sdp.to_string()))
    }

    #[func]
    fn add_ice_candidate(&self, candidate: GString, sdp_mid: GString, sdp_mline_index: i64) -> Error {
        self.with_handle(|h| {
            h.add_ice_candidate(candidate.to_string(), sdp_mid.to_string(), sdp_mline_index)
        })
    }

    /// Options: `ordered` (bool, default true), `max_retransmits` (int),
    /// `max_packet_life_time` (int, ms).
    #[func]
    fn create_data_channel(&mut self, label: GString, options: VarDictionary) -> Option<Gd<RtcChannel>> {
        let Some(handle) = &self.handle else {
            godot_error!("RtcPeer: call initialize() first");
            return None;
        };
        let opts = ChannelOptions {
            ordered: options.get("ordered").and_then(|v| v.try_to().ok()).unwrap_or(true),
            max_retransmits: options
                .get("max_retransmits")
                .and_then(|v| v.try_to::<i64>().ok())
                .and_then(|n| u16::try_from(n).ok()),
            max_packet_life_time: options
                .get("max_packet_life_time")
                .and_then(|v| v.try_to::<i64>().ok())
                .and_then(|n| u16::try_from(n).ok()),
        };
        let channel = RtcChannel::from_handle(handle.create_data_channel(&label.to_string(), opts));
        self.channels.push(channel.clone());
        Some(channel)
    }

    /// One of "new", "connecting", "connected", "disconnected", "failed", "closed".
    #[func]
    fn get_connection_state(&self) -> GString {
        self.handle
            .as_ref()
            .map_or("closed", |h| h.state().as_str())
            .into()
    }

    #[func]
    fn close(&mut self) {
        // Dropping the handle closes the connection.
        self.handle = None;
        self.channels.clear();
    }

    /// Dispatch pending events as signals. Call once per frame.
    #[func]
    fn poll(&mut self) {
        let events = match &mut self.handle {
            Some(h) => h.drain(),
            None => return,
        };
        for event in events {
            match event {
                PeerEvent::LocalDescription { sdp_type, sdp } => self
                    .signals()
                    .session_description_created()
                    .emit(&GString::from(&sdp_type), &GString::from(&sdp)),
                PeerEvent::IceCandidate {
                    candidate,
                    sdp_mid,
                    sdp_mline_index,
                } => self.signals().ice_candidate_created().emit(
                    &GString::from(&candidate),
                    &GString::from(&sdp_mid),
                    sdp_mline_index,
                ),
                PeerEvent::ConnectionState(state) => self
                    .signals()
                    .connection_state_changed()
                    .emit(&GString::from(state.as_str())),
                PeerEvent::DataChannel(handle) => {
                    let channel = RtcChannel::from_handle(handle);
                    self.channels.push(channel.clone());
                    self.signals().data_channel_received().emit(&channel);
                }
                PeerEvent::Error(msg) => self.signals().error().emit(&GString::from(&msg)),
            }
        }

        // Hold a base guard so channel signal handlers may call back into this peer.
        let channels = self.channels.clone();
        let _guard = self.base_mut();
        for mut channel in channels {
            channel.bind_mut().poll();
        }
    }
}

impl RtcPeer {
    fn with_handle(&self, f: impl FnOnce(&PeerHandle)) -> Error {
        match &self.handle {
            Some(h) => {
                f(h);
                Error::OK
            }
            None => {
                godot_error!("RtcPeer: call initialize() first");
                Error::ERR_UNCONFIGURED
            }
        }
    }
}

/// Parse `{"iceServers": [{"urls": ..., "username": ..., "credential": ...}]}`.
/// `urls` may be a single string or an array of strings.
pub fn parse_ice_servers(config: &VarDictionary) -> Vec<IceServer> {
    let Some(servers) = config
        .get("iceServers")
        .and_then(|v| v.try_to::<VarArray>().ok())
    else {
        return Vec::new();
    };

    servers
        .iter_shared()
        .filter_map(|entry| entry.try_to::<VarDictionary>().ok())
        .map(|entry| {
            let urls = match entry.get("urls") {
                Some(v) => match v.try_to::<PackedStringArray>() {
                    Ok(list) => list.as_slice().iter().map(|s| s.to_string()).collect(),
                    Err(_) => v.try_to::<GString>().map(|s| vec![s.to_string()]).unwrap_or_default(),
                },
                None => Vec::new(),
            };
            let text = |key: &str| {
                entry
                    .get(key)
                    .and_then(|v| v.try_to::<GString>().ok())
                    .map(|s| s.to_string())
                    .unwrap_or_default()
            };
            IceServer {
                urls,
                username: text("username"),
                credential: text("credential"),
            }
        })
        .collect()
}
