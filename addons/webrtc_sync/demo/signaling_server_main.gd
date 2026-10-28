extends Node
## Standalone signaling server: godot --headless res://addons/webrtc_sync/demo/signaling_server_main.tscn

@export var port := 9080


func _ready() -> void:
	var server := RtcSignalingServer.new()
	add_child(server)
	server.client_joined.connect(func(id): print("client %d joined" % id))
	server.client_left.connect(func(id): print("client %d left" % id))
	var err := server.listen(port)
	print("Signaling server listening on %d" % port if err == OK else "listen failed: %s" % error_string(err))
