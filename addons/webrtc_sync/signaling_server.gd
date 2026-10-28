class_name RtcSignalingServer
extends Node
## Minimal WebSocket signaling server for RtcSession / RtcLobby.
##
## Assigns each client an id and relays offers, answers and ICE candidates
## between them. It never sees game traffic, which flows peer-to-peer.
## Host it inside one game instance, or headless on a server:
##   godot --headless res://addons/webrtc_sync/demo/signaling_server_main.tscn
##
## Protocol (JSON text frames):
##   server -> client  {"type": "welcome", "id": int, "peers": [int]}
##                     {"type": "peer_joined", "id": int}
##                     {"type": "peer_left", "id": int}
##                     {"type": "relay", "from": int, "data": {...}}
##   client -> server  {"type": "relay", "to": int, "data": {...}}

signal client_joined(id: int)
signal client_left(id: int)

var _tcp := TCPServer.new()
var _pending: Array[WebSocketPeer] = []
var _clients: Dictionary[int, WebSocketPeer] = {}
var _next_id := 1


func listen(port: int, bind_address := "*") -> Error:
	stop()
	return _tcp.listen(port, bind_address)


func stop() -> void:
	for ws: WebSocketPeer in _clients.values():
		ws.close()
	_clients.clear()
	_pending.clear()
	_tcp.stop()


func is_listening() -> bool:
	return _tcp.is_listening()


func _process(_delta: float) -> void:
	if not _tcp.is_listening():
		return

	while _tcp.is_connection_available():
		var ws := WebSocketPeer.new()
		ws.accept_stream(_tcp.take_connection())
		_pending.append(ws)

	for ws in _pending.duplicate():
		ws.poll()
		match ws.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				_pending.erase(ws)
				_admit(ws)
			WebSocketPeer.STATE_CLOSED:
				_pending.erase(ws)

	for id: int in _clients.keys():
		var ws := _clients[id]
		ws.poll()
		while ws.get_available_packet_count() > 0:
			_handle(id, ws.get_packet().get_string_from_utf8())
		if ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			_clients.erase(id)
			_broadcast({"type": "peer_left", "id": id})
			client_left.emit(id)


func _admit(ws: WebSocketPeer) -> void:
	var id := _next_id
	_next_id += 1
	_send(ws, {"type": "welcome", "id": id, "peers": _clients.keys()})
	_broadcast({"type": "peer_joined", "id": id})
	_clients[id] = ws
	client_joined.emit(id)


func _handle(from: int, text: String) -> void:
	var msg: Variant = JSON.parse_string(text)
	if not msg is Dictionary or msg.get("type") != "relay":
		return
	var to := int(msg.get("to", 0))
	if _clients.has(to):
		_send(_clients[to], {"type": "relay", "from": from, "data": msg.get("data", {})})


func _broadcast(msg: Dictionary) -> void:
	for ws: WebSocketPeer in _clients.values():
		_send(ws, msg)


func _send(ws: WebSocketPeer, msg: Dictionary) -> void:
	ws.send_text(JSON.stringify(msg))
