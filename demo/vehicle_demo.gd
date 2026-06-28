extends Node3D

# A VehicleBody3D you drive with the Moza wheel + pedals. Force feedback comes
# from the real vehicle physics (front tire slip angle + grip), and the wheel's
# full physical range is mapped onto the car's steering.

const MAX_STEER := 0.6          # rad, front wheel angle at full car lock
const CAR_LOCK_DEG := 540.0     # wheel degrees (lock-to-lock) that give full car lock
const WHEEL_RANGE_DEG := 2540.0 # physical lock-to-lock range configured on the Moza
const ENGINE_FORCE := 2200.0
const BRAKE_FORCE := 40.0
const TOP_SPEED := 45.0         # m/s, normalizes speed for the force model
const FRONT_AXLE := 1.3         # distance CoM -> front axle (matches wheel placement)

var car: VehicleBody3D
var front_left: VehicleWheel3D
var front_right: VehicleWheel3D
var rear_left: VehicleWheel3D
var rear_right: VehicleWheel3D
var camera: Camera3D
var label: Label

var ffb: FFBWheel
var model: VehicleFFBModel
var status := ""


func _ready() -> void:
	_build_world()
	_build_car()
	_build_camera()
	_build_ui()
	_setup_ffb()


# ---------------------------------------------------------------- world
func _build_world() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.background_mode = Environment.BG_SKY
	e.sky = sky
	e.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.environment = e
	add_child(env)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -40, 0)
	sun.shadow_enabled = true
	add_child(sun)

	var ground := StaticBody3D.new()
	var gcol := CollisionShape3D.new()
	var gbox := BoxShape3D.new()
	gbox.size = Vector3(1000, 1, 1000)
	gcol.shape = gbox
	gcol.position = Vector3(0, -0.5, 0)
	ground.add_child(gcol)
	var gmesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(1000, 1000)
	var gmat := StandardMaterial3D.new()
	gmat.albedo_color = Color(0.22, 0.45, 0.25)
	plane.material = gmat
	gmesh.mesh = plane
	ground.add_child(gmesh)
	add_child(ground)

	# grid of solid pillars (with collision) to drive around / into
	for x in range(-5, 6):
		for z in range(-5, 6):
			if x == 0 and z == 0:
				continue
			add_child(_make_pillar(Vector3(x * 20.0, 1.5, z * 20.0)))


func _make_pillar(pos: Vector3) -> StaticBody3D:
	var p := StaticBody3D.new()
	p.position = pos
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1, 3, 1)
	col.shape = box
	p.add_child(col)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1, 3, 1)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.3, 0.2)
	bm.material = mat
	mi.mesh = bm
	p.add_child(mi)
	return p


# ---------------------------------------------------------------- car
func _build_car() -> void:
	car = VehicleBody3D.new()
	car.mass = 800.0
	car.position = Vector3(0, 1.0, 0)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.8, 0.6, 4.0)
	col.shape = box
	car.add_child(col)

	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.8, 0.6, 4.0)
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.2, 0.45, 0.9)
	bm.material = bmat
	body.mesh = bm
	car.add_child(body)

	front_left = _make_wheel(Vector3(-0.85, 0.0, -FRONT_AXLE), true, false)
	front_right = _make_wheel(Vector3(0.85, 0.0, -FRONT_AXLE), true, false)
	rear_left = _make_wheel(Vector3(-0.85, 0.0, FRONT_AXLE), false, true)
	rear_right = _make_wheel(Vector3(0.85, 0.0, FRONT_AXLE), false, true)
	for w in [front_left, front_right, rear_left, rear_right]:
		car.add_child(w)

	add_child(car)


func _make_wheel(pos: Vector3, steer: bool, traction: bool) -> VehicleWheel3D:
	var w := VehicleWheel3D.new()
	w.position = pos
	w.use_as_steering = steer
	w.use_as_traction = traction
	w.wheel_radius = 0.35
	w.wheel_rest_length = 0.4
	w.wheel_friction_slip = 3.0
	w.suspension_stiffness = 30.0
	w.suspension_travel = 0.3
	w.suspension_max_force = 8000.0
	w.damping_compression = 0.5
	w.damping_relaxation = 0.6

	var vm := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.35
	cyl.bottom_radius = 0.35
	cyl.height = 0.25
	var wmat := StandardMaterial3D.new()
	wmat.albedo_color = Color(0.08, 0.08, 0.08)
	cyl.material = wmat
	vm.mesh = cyl
	vm.rotation_degrees = Vector3(0, 0, 90)  # cylinder axis -> along the axle (X)
	w.add_child(vm)
	return w


# ---------------------------------------------------------------- camera / ui
func _build_camera() -> void:
	camera = Camera3D.new()
	camera.position = Vector3(0, 5, 12)
	camera.current = true
	add_child(camera)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	# semi-transparent top strip so it doesn't cover the view
	var panel := ColorRect.new()
	panel.color = Color(0, 0, 0, 0.5)
	panel.anchor_right = 1.0
	panel.offset_bottom = 96.0
	layer.add_child(panel)
	label = Label.new()
	label.add_theme_font_size_override("font_size", 14)
	label.position = Vector2(10, 6)
	panel.add_child(label)
	add_child(layer)


# ---------------------------------------------------------------- ffb
func _setup_ffb() -> void:
	model = VehicleFFBModel.new()
	ffb = FFBWheel.new()
	ffb.force_model = model
	ffb.steering_range_deg = WHEEL_RANGE_DEG
	ffb.opened.connect(func(n): print("FFB wheel: ", n))
	ffb.open_failed.connect(func(r): status = r + " (keyboard only)")
	add_child(ffb)


# ---------------------------------------------------------------- loop
func _physics_process(delta: float) -> void:
	var car_input := 0.0
	var throttle := 0.0
	var brake := 0.0

	if ffb.is_open():
		ffb.poll(delta)
		car_input = clampf(ffb.steering_angle_deg() / (CAR_LOCK_DEG * 0.5), -1.0, 1.0)
		throttle = ffb.throttle
		brake = ffb.brake
	else:
		car_input = Input.get_axis("ui_right", "ui_left")
		throttle = 1.0 if Input.is_action_pressed("ui_up") else 0.0
		brake = 1.0 if Input.is_action_pressed("ui_down") else 0.0

	car.steering = lerpf(car.steering, -car_input * MAX_STEER, 0.5)
	car.engine_force = -throttle * ENGINE_FORCE  # -Z is forward (toward steering wheels)
	car.brake = brake * BRAKE_FORCE

	# --- vehicle state for FFB ---
	var v_local := car.global_transform.basis.inverse() * car.linear_velocity
	var v_fwd := -v_local.z
	var v_lat := v_local.x
	var yaw_rate := car.angular_velocity.y
	# lateral velocity at the front axle, then its slip angle vs the wheel angle
	var v_lat_front := v_lat - FRONT_AXLE * yaw_rate
	var heading := atan2(v_lat_front, maxf(absf(v_fwd), 2.0))
	var slip := car.steering - heading

	var grip := 0.0
	if front_left.is_in_contact() and front_right.is_in_contact():
		grip = (front_left.get_skidinfo() + front_right.get_skidinfo()) * 0.5

	if ffb.is_open():
		ffb.state.speed = clampf(absf(v_fwd) / TOP_SPEED, 0.0, 1.0)
		ffb.state.slip = slip
		ffb.state.surface_friction = grip
		ffb.update_force(delta)

	_update_camera(delta)
	_redraw(v_fwd, slip, grip)


func _update_camera(_delta: float) -> void:
	var target := car.global_position + car.global_transform.basis * Vector3(0, 3.0, 8.0)
	camera.global_position = camera.global_position.lerp(target, 0.12)
	camera.look_at(car.global_position + Vector3.UP * 0.5, Vector3.UP)


func _redraw(speed: float, slip: float, grip: float) -> void:
	var src := ffb.device.get_device_name() if ffb.is_open() else status
	var lines := []
	lines.append("Vehicle FFB — %s" % src)
	lines.append("speed %5.1f m/s    slip %+.3f rad    front grip %.2f" % [speed, slip, grip])
	lines.append("wheel %+5.0f°   car steer %+.2f   throttle %.2f   brake %.2f   torque %+.3f" % [
		ffb.steering_angle_deg(), car.steering, ffb.throttle, ffb.brake, ffb.last_torque])
	lines.append("[R] reset car    [C] flip force direction")
	label.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_R:
				car.linear_velocity = Vector3.ZERO
				car.angular_velocity = Vector3.ZERO
				car.global_transform = Transform3D(Basis(), Vector3(0, 1.0, 0))
			KEY_C:
				if ffb.is_open():
					ffb.set_inverted(not ffb.inverted)


func _exit_tree() -> void:
	if ffb != null:
		ffb.close()
