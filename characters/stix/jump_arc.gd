class_name JumpArc
extends RefCounted
## The ballistic numbers of a Stix jump, shared by the character (to move)
## and by level building (to place platforms the character can reach).
## Heights are px above the takeoff ground, measured at the feet.

var height: float
var time_to_apex: float
var run_speed: float

var gravity: float:
	get:
		return 2.0 * height / (time_to_apex * time_to_apex)
var launch_speed: float:
	get:
		return gravity * time_to_apex


func _init(jump_height: float, apex_time: float, horizontal_speed: float) -> void:
	height = jump_height
	time_to_apex = apex_time
	run_speed = horizontal_speed


## Tallest step up the feet can land on, keeping clearance px to spare at the peak.
func max_rise(clearance := 16.0) -> float:
	return height - clearance


## Seconds from launch until the feet come back down to rise px above takeoff.
## Pass a negative rise for landing below the takeoff ground.
func air_time_to(rise: float) -> float:
	return time_to_apex + sqrt(2.0 * maxf(height - rise, 0.0) / gravity)


## Farthest horizontal distance from the launch point that still lands at rise.
func reach(rise: float) -> float:
	return run_speed * air_time_to(rise)
