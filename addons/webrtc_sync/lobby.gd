class_name RtcLobby
extends Node
## Connects an RtcSession to an RtcSignalingServer over WebSocket.
##
## Once joined, the lobby starts the session with the server-assigned id and
## adds/removes peers as they come and go. Swap this out if you use a different
## signaling transport (HTTP, a matchmaking service, Steam, ...): all the
## session needs is `start()`, `add_peer()`, `remove_peer()`,
## `handle_signaling_message()` and something listening to `signaling_message`.

signal joined(local_id: int)
signal left

@export var session: RtcSession

var _ws := WebSocketPeer.new()
var _joined := false


func _ready() -> void:
	assert(session != null, "RtcLobby needs an RtcSession")
	session.signaling_message.connect(_on_session_signaling)


func join(url: String) -> Error:
	leave()
	return _ws.connect_to_url(url)


func leave() -> void:
	if _ws.get_ready_state() != WebSocketPeer.STATE_CLOSED:
		_ws.close()
	if _joined:
		_joined = false
		session.close()
		left.emit()


func is_joined() -> bool:
	return _joined


func _process(_delta: float) -> void:
	_ws.poll()
	while _ws.get_available_packet_count() > 0:
		var msg: Variant = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
		if msg is Dictionary:
			_handle(msg)
	if _joined and _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		# Losing the signaling server does not break existing peer connections,
		# but no new peers can join. Policy is up to the game; we just report it.
		_joined = false
		left.emit()


func _handle(msg: Dictionary) -> void:
	match msg.get("type"):
		"welcome":
			var id := int(msg["id"])
			session.start(id)
			_joined = true
			joined.emit(id)
			for peer in msg.get("peers", []):
				session.add_peer(int(peer))
		"peer_joined":
			session.add_peer(int(msg["id"]))
		"peer_left":
			session.remove_peer(int(msg["id"]))
		"relay":
			var data: Dictionary = msg.get("data", {})
			# JSON turns ints into floats.
			if data.has("sdp_mline_index"):
				data["sdp_mline_index"] = int(data["sdp_mline_index"])
			session.handle_signaling_message(int(msg["from"]), data)


func _on_session_signaling(peer_id: int, message: Dictionary) -> void:
	_ws.send_text(JSON.stringify({"type": "relay", "to": peer_id, "data": message}))
