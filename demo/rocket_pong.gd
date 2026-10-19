extends Control

const COURT_SIZE := Vector2(960.0, 540.0)
const PADDLE_SIZE := Vector2(14.0, 94.0)
const PADDLE_MARGIN := 34.0
const BALL_RADIUS := 8.0

const PADDLE_ACCEL := 925.0
const PADDLE_FRICTION := 0.988
const PADDLE_BRAKE_IMPULSE := 1.1
const PADDLE_MAX_SPEED := 520.0

const BALL_BASE_SPEED := 410.0
const BALL_MAX_SPEED := 900.0
const HIT_SPEED_GAIN := 0.17
const HIT_POSITION_GAIN := 250.0
const PADDLE_VELOCITY_SPIN := 0.34
const SPIN_CURVE_GAIN := 2.8
const SPIN_CURVE_DECAY := 0.994
const SPIN_CURVE_MAX := 760.0

const GOAL_REWARD := 8.0
const GOAL_LOSS_PENALTY := 5.0
const OPPONENT_RETURN_PENALTY := 0.16
const OPPONENT_RETURN_PENALTY_CAP := 1.25
const SPIN_REWARD := 1.4
const DOUBLE_HIT_BONUS := 0.9
const MISS_STREAK_PENALTY := 0.28
const MISS_STREAK_PENALTY_CAP := 1.15

const SERVE_DELAY := 0.35
const DECISION_INTERVAL := 1.0 / 30.0
const SIM_SUBSTEPS := 2
const LEARNING_RATE := 0.0025
const REWARD_SCALE := 0.035
const GAMMA := 0.985
const ENTROPY := 0.002
const HISTORY_LIMIT := 1200
const WARMUP_EPISODES := 1000
const WARMUP_MAX_STEPS := 1800
const MAX_RALLY_BEFORE_CHAOS := 36

const DEFAULT_STEERING_LIMIT_DEG := 45.0
const DEFAULT_WHEEL_RANGE_DEG := 900.0
const SCORE_FONT_SIZE := 54
const HUMAN_ENGINE_IMPULSE := 1280.0
const HUMAN_IDLE_DAMPING := 0.055
const HUMAN_INERTIA := 0.24
const HUMAN_CENTERING := 0.18
const HUMAN_LOSS_EMPTY_TIME := 0.9

class Paddle:
	var side := "left"
	var x := 0.0
	var y := 0.0
	var vy := 0.0
	var thrust := 0.0
	var brake := 0.0
	var touches := 0
	var miss_streak := 0


class Ball:
	var x := COURT_SIZE.x * 0.5
	var y := COURT_SIZE.y * 0.5
	var vx := BALL_BASE_SPEED
	var vy := 0.0
	var curve := 0.0


class TinyPolicyNet:
	var input_size: int
	var hidden_size: int
	var output_size: int
	var w1: Array[PackedFloat64Array] = []
	var b1 := PackedFloat64Array()
	var w2: Array[PackedFloat64Array] = []
	var b2 := PackedFloat64Array()
	var traces: Array[Dictionary] = []
	var avg_abs_reward := 0.0
	var steps := 0

	func _init(p_input_size: int, p_hidden_size: int, p_output_size: int) -> void:
		input_size = p_input_size
		hidden_size = p_hidden_size
		output_size = p_output_size
		w1 = _make_matrix(hidden_size, input_size, 0.38)
		b1 = PackedFloat64Array()
		b1.resize(hidden_size)
		w2 = _make_matrix(output_size, hidden_size, 0.26)
		b2 = PackedFloat64Array()
		b2.resize(output_size)

	func _make_matrix(rows: int, cols: int, scale: float) -> Array[PackedFloat64Array]:
		var matrix: Array[PackedFloat64Array] = []
		for r in rows:
			var row := PackedFloat64Array()
			row.resize(cols)
			for c in cols:
				row[c] = randf_range(-scale, scale)
			matrix.append(row)
		return matrix

	func forward(input: PackedFloat64Array) -> Dictionary:
		var hidden := PackedFloat64Array()
		hidden.resize(hidden_size)
		for i in hidden_size:
			var sum := b1[i]
			for j in input_size:
				sum += w1[i][j] * input[j]
			hidden[i] = tanh(sum)

		var output := PackedFloat64Array()
		output.resize(output_size)
		for i in output_size:
			var sum := b2[i]
			for j in hidden_size:
				sum += w2[i][j] * hidden[j]
			output[i] = tanh(sum)
		return {"hidden": hidden, "output": output}

	func act(input: PackedFloat64Array, learn_enabled: bool, teacher: Dictionary = {}) -> Dictionary:
		var forward_pass := forward(input)
		var raw: PackedFloat64Array = forward_pass.output
		var explore := maxf(0.02, 0.25 * exp(-float(steps) / 22000.0))
		var neural_thrust := clampf(raw[0] + randf_range(-explore, explore), -1.0, 1.0)
		var neural_brake := clampf(maxf(0.0, raw[1]) + randf_range(-explore * 0.25, explore * 0.25), 0.0, 1.0)

		var teacher_blend := maxf(0.04, 0.45 * exp(-float(steps) / 28000.0)) if not teacher.is_empty() else 0.0
		var thrust := neural_thrust
		var brake := neural_brake
		if not teacher.is_empty():
			thrust = clampf(neural_thrust * (1.0 - teacher_blend) + teacher.thrust * teacher_blend, -1.0, 1.0)
			brake = clampf(neural_brake * (1.0 - teacher_blend) + teacher.brake * teacher_blend, 0.0, 1.0)

		if not learn_enabled:
			return {"thrust": thrust, "brake": brake}

		if not teacher.is_empty():
			_imitate(input, forward_pass.hidden, raw, teacher, 0.55 * teacher_blend)

		traces.append({
			"input": input.duplicate(),
			"hidden": forward_pass.hidden,
			"raw": raw.duplicate(),
			"action": PackedFloat64Array([thrust, brake])
		})
		if traces.size() > HISTORY_LIMIT:
			traces.pop_front()
		steps += 1
		return {"thrust": thrust, "brake": brake}

	func learn(reward: float) -> void:
		if not is_finite(reward) or traces.is_empty():
			return

		avg_abs_reward = avg_abs_reward * 0.995 + absf(reward) * 0.005
		var discounted := reward * REWARD_SCALE
		var batch := traces.duplicate()
		traces.clear()
		for index in range(batch.size() - 1, -1, -1):
			var trace: Dictionary = batch[index]
			var advantage := discounted
			var sign := signf(advantage) if advantage != 0.0 else 1.0
			var thrust_target := clampf(trace.action[0] * sign, -1.0, 1.0)
			var brake_target := clampf((trace.action[1] * 2.0 - 1.0) * sign, -1.0, 1.0)
			var errors := PackedFloat64Array([
				clampf(thrust_target - trace.raw[0], -2.0, 2.0) * absf(advantage),
				clampf(brake_target - trace.raw[1], -2.0, 2.0) * absf(advantage) * 0.65
			])
			_backprop(trace.input, trace.hidden, trace.raw, errors)
			discounted *= GAMMA

	func _imitate(input: PackedFloat64Array, hidden: PackedFloat64Array, output: PackedFloat64Array, teacher: Dictionary, weight: float) -> void:
		var errors := PackedFloat64Array([
			clampf(teacher.thrust - output[0], -2.0, 2.0) * weight,
			clampf((teacher.brake * 2.0 - 1.0) - output[1], -2.0, 2.0) * weight * 0.7
		])
		_backprop(input, hidden, output, errors)

	func _backprop(input: PackedFloat64Array, hidden: PackedFloat64Array, output: PackedFloat64Array, errors: PackedFloat64Array) -> void:
		var hidden_deltas := PackedFloat64Array()
		hidden_deltas.resize(hidden_size)
		for o in output_size:
			var d_out := errors[o] * (1.0 - output[o] * output[o])
			for j in hidden_size:
				hidden_deltas[j] += d_out * w2[o][j]
				w2[o][j] += LEARNING_RATE * d_out * hidden[j]
			b2[o] += LEARNING_RATE * d_out

		for j in hidden_size:
			var d_hidden := hidden_deltas[j] * (1.0 - hidden[j] * hidden[j])
			for k in input_size:
				w1[j][k] += LEARNING_RATE * d_hidden * input[k]
			b1[j] += LEARNING_RATE * d_hidden

		if randf() < ENTROPY:
			var row_index := randi_range(0, w1.size() - 1)
			var col_index := randi_range(0, w1[row_index].size() - 1)
			w1[row_index][col_index] += randf_range(-0.02, 0.02)


class PongSim:
	var brain: TinyPolicyNet
	var visible := false
	var human_left := false
	var human_control := {"thrust": 0.0, "brake": 0.0}
	var paused := false
	var visible_steps := 0
	var decision_clock := 0.0
	var left_score := 0
	var right_score := 0
	var rally := 0
	var serve_timer := SERVE_DELAY
	var double_hits := 0
	var miss_penalties := 0
	var max_miss_streak := 0
	var last_event := ""
	var left := Paddle.new()
	var right := Paddle.new()
	var ball := Ball.new()

	func _init(p_brain: TinyPolicyNet, p_visible: bool) -> void:
		brain = p_brain
		visible = p_visible
		left = _make_paddle("left")
		right = _make_paddle("right")
		reset_ball([-1, 1].pick_random())

	func _make_paddle(side: String) -> Paddle:
		var paddle := Paddle.new()
		paddle.side = side
		paddle.x = PADDLE_MARGIN if side == "left" else COURT_SIZE.x - PADDLE_MARGIN - PADDLE_SIZE.x
		paddle.y = COURT_SIZE.y * 0.5 - PADDLE_SIZE.y * 0.5
		return paddle

	func reset_match(randomize_paddles: bool = false) -> void:
		left_score = 0
		right_score = 0
		rally = 0
		serve_timer = SERVE_DELAY
		decision_clock = 0.0
		double_hits = 0
		miss_penalties = 0
		max_miss_streak = 0
		_reset_paddle(left, randomize_paddles)
		_reset_paddle(right, randomize_paddles)
		reset_ball([-1, 1].pick_random())

	func _reset_paddle(paddle: Paddle, randomize: bool) -> void:
		paddle.y = randf_range(70.0, COURT_SIZE.y - PADDLE_SIZE.y - 70.0) if randomize else COURT_SIZE.y * 0.5 - PADDLE_SIZE.y * 0.5
		paddle.vy = 0.0
		paddle.thrust = 0.0
		paddle.brake = 0.0
		paddle.touches = 0
		paddle.miss_streak = 0

	func reset_ball(direction: int) -> void:
		ball.x = COURT_SIZE.x * 0.5
		ball.y = COURT_SIZE.y * 0.5
		ball.vx = direction * randf_range(BALL_BASE_SPEED * 0.88, BALL_BASE_SPEED * 1.1)
		ball.vy = randf_range(-170.0, 170.0)
		ball.curve = 0.0
		serve_timer = SERVE_DELAY if visible else 0.0
		rally = 0

	func observation_for_side(side: String) -> PackedFloat64Array:
		var paddle := left if side == "left" else right
		var enemy := right if side == "left" else left
		var mirror := 1.0 if side == "left" else -1.0
		var ball_x := ball.x if side == "left" else COURT_SIZE.x - ball.x
		return PackedFloat64Array([
			(ball_x - COURT_SIZE.x * 0.5) / (COURT_SIZE.x * 0.5),
			(ball.y - COURT_SIZE.y * 0.5) / (COURT_SIZE.y * 0.5),
			ball.vx * mirror / BALL_MAX_SPEED,
			ball.vy / BALL_MAX_SPEED,
			ball.curve / SPIN_CURVE_MAX,
			(paddle.y + PADDLE_SIZE.y * 0.5 - COURT_SIZE.y * 0.5) / (COURT_SIZE.y * 0.5),
			paddle.vy / PADDLE_MAX_SPEED,
			paddle.thrust,
			paddle.brake,
			(enemy.y + PADDLE_SIZE.y * 0.5 - COURT_SIZE.y * 0.5) / (COURT_SIZE.y * 0.5),
			enemy.vy / PADDLE_MAX_SPEED,
			enemy.thrust,
			enemy.brake
		])

	func predict_ball_y_after(time: float) -> float:
		var min_y := BALL_RADIUS
		var max_y := COURT_SIZE.y - BALL_RADIUS
		var span := max_y - min_y
		var period := span * 2.0
		var y := fmod(ball.y + ball.vy * time + 0.5 * ball.curve * time * time - min_y, period)
		if y < 0.0:
			y += period
		if y > span:
			y = period - y
		return min_y + y

	func expert_control(side: String) -> Dictionary:
		var paddle := left if side == "left" else right
		var target_y := COURT_SIZE.y * 0.5
		if side == "left" and ball.vx < 0.0:
			target_y = predict_ball_y_after(maxf(0.0, (ball.x - (paddle.x + PADDLE_SIZE.x + BALL_RADIUS)) / absf(ball.vx)))
		if side == "right" and ball.vx > 0.0:
			target_y = predict_ball_y_after(maxf(0.0, (paddle.x - BALL_RADIUS - ball.x) / absf(ball.vx)))

		var error := target_y - (paddle.y + PADDLE_SIZE.y * 0.5)
		var desired_velocity := clampf(error * 5.2, -PADDLE_MAX_SPEED * 0.72, PADDLE_MAX_SPEED * 0.72)
		var velocity_error := desired_velocity - paddle.vy
		var thrust := clampf(velocity_error / 430.0, -1.0, 1.0)
		var near_target := absf(error) < 34.0
		var moving_away := signf(error) != 0.0 and signf(error) != signf(paddle.vy)
		var brake := clampf((absf(paddle.vy) / 520.0 if near_target else 0.0) + (0.35 if moving_away and absf(paddle.vy) > 140.0 else 0.0), 0.0, 1.0)
		return {"thrust": thrust, "brake": brake}

	func update_actions(dt: float, learn_enabled: bool) -> void:
		decision_clock -= dt
		if decision_clock > 0.0:
			return
		decision_clock = DECISION_INTERVAL

		var left_control := human_control if human_left else brain.act(observation_for_side("left"), learn_enabled, expert_control("left"))
		var right_control := brain.act(observation_for_side("right"), learn_enabled, expert_control("right"))
		left.thrust = left_control.thrust
		left.brake = left_control.brake
		right.thrust = right_control.thrust
		right.brake = right_control.brake

	func apply_paddle_physics(paddle: Paddle, dt: float) -> void:
		paddle.vy += paddle.thrust * PADDLE_ACCEL * dt
		paddle.vy *= pow(PADDLE_FRICTION, dt * 60.0)
		var brake_step := PADDLE_ACCEL * PADDLE_BRAKE_IMPULSE * paddle.brake * dt
		if paddle.vy > 0.0:
			paddle.vy = maxf(0.0, paddle.vy - brake_step)
		if paddle.vy < 0.0:
			paddle.vy = minf(0.0, paddle.vy + brake_step)
		paddle.vy = clampf(paddle.vy, -PADDLE_MAX_SPEED, PADDLE_MAX_SPEED)
		paddle.y += paddle.vy * dt
		if paddle.y < 0.0:
			paddle.y = 0.0
			paddle.vy *= -0.22
		if paddle.y > COURT_SIZE.y - PADDLE_SIZE.y:
			paddle.y = COURT_SIZE.y - PADDLE_SIZE.y
			paddle.vy *= -0.22

	func ball_overlaps_paddle(paddle: Paddle) -> bool:
		return ball.x + BALL_RADIUS > paddle.x and ball.x - BALL_RADIUS < paddle.x + PADDLE_SIZE.x and ball.y + BALL_RADIUS > paddle.y and ball.y - BALL_RADIUS < paddle.y + PADDLE_SIZE.y

	func bounce_from_paddle(paddle: Paddle, side_sign: int, learn_enabled: bool) -> void:
		var center := paddle.y + PADDLE_SIZE.y * 0.5
		var normalized_hit := clampf((ball.y - center) / (PADDLE_SIZE.y * 0.5), -1.0, 1.0)
		var incoming_speed := Vector2(ball.vx, ball.vy).length()
		var speed := clampf(incoming_speed + absf(paddle.vy) * HIT_SPEED_GAIN + 8.0, BALL_BASE_SPEED, BALL_MAX_SPEED)
		var new_vy := clampf(normalized_hit * HIT_POSITION_GAIN + paddle.vy * PADDLE_VELOCITY_SPIN, -speed * 0.86, speed * 0.86)
		ball.vx = side_sign * sqrt(maxf(80.0 * 80.0, speed * speed - new_vy * new_vy))
		ball.vy = new_vy
		ball.curve = clampf(paddle.vy * SPIN_CURVE_GAIN, -SPIN_CURVE_MAX, SPIN_CURVE_MAX)
		ball.x = paddle.x + PADDLE_SIZE.x + BALL_RADIUS if side_sign > 0 else paddle.x - BALL_RADIUS
		paddle.touches += 1
		rally += 1
		last_event = "left_hit" if paddle.side == "left" else "right_hit"

		var double_bonus := DOUBLE_HIT_BONUS if rally >= 2 else 0.0
		if double_bonus > 0.0:
			double_hits += 1
		var return_penalty := minf(OPPONENT_RETURN_PENALTY_CAP, maxf(0.0, rally - 2.0) * OPPONENT_RETURN_PENALTY)
		var spin_bonus := SPIN_REWARD * clampf(absf(ball.curve) / SPIN_CURVE_MAX, 0.0, 1.0)
		if learn_enabled:
			brain.learn(0.55 + minf(0.45, rally * 0.025) + double_bonus * 0.55 + spin_bonus - return_penalty)
		if rally >= MAX_RALLY_BEFORE_CHAOS:
			if learn_enabled:
				brain.learn(-2.5)
			reset_ball([-1, 1].pick_random())

	func apply_miss_penalty(loser: Paddle, winner: Paddle, learn_enabled: bool) -> void:
		loser.miss_streak += 1
		winner.miss_streak = 0
		max_miss_streak = maxi(max_miss_streak, loser.miss_streak)
		miss_penalties += 1
		if learn_enabled:
			var streak_penalty := minf(MISS_STREAK_PENALTY_CAP, loser.miss_streak * MISS_STREAK_PENALTY)
			brain.learn(GOAL_REWARD - GOAL_LOSS_PENALTY - streak_penalty)

	func update_ball(dt: float, learn_enabled: bool) -> bool:
		last_event = ""
		if serve_timer > 0.0:
			serve_timer -= dt
			return false

		ball.vy += ball.curve * dt
		ball.curve *= pow(SPIN_CURVE_DECAY, dt * 60.0)
		ball.x += ball.vx * dt
		ball.y += ball.vy * dt

		if ball.y < BALL_RADIUS:
			ball.y = BALL_RADIUS
			ball.vy = absf(ball.vy)
			ball.curve = absf(ball.curve) * 0.72
		if ball.y > COURT_SIZE.y - BALL_RADIUS:
			ball.y = COURT_SIZE.y - BALL_RADIUS
			ball.vy = -absf(ball.vy)
			ball.curve = -absf(ball.curve) * 0.72
		if ball.vx < 0.0 and ball_overlaps_paddle(left):
			bounce_from_paddle(left, 1, learn_enabled)
			return false
		if ball.vx > 0.0 and ball_overlaps_paddle(right):
			bounce_from_paddle(right, -1, learn_enabled)
			return false
		if ball.x < -BALL_RADIUS * 2.0:
			right_score += 1
			apply_miss_penalty(left, right, learn_enabled)
			last_event = "left_lost"
			reset_ball(1)
			return true
		if ball.x > COURT_SIZE.x + BALL_RADIUS * 2.0:
			left_score += 1
			apply_miss_penalty(right, left, learn_enabled)
			last_event = "left_scored"
			reset_ball(-1)
			return true
		return false

	func step(dt: float, learn_enabled: bool = true) -> bool:
		if visible:
			visible_steps += 1
		update_actions(dt, learn_enabled)
		var sub_dt := dt / SIM_SUBSTEPS
		var scored := false
		for i in SIM_SUBSTEPS:
			apply_paddle_physics(left, sub_dt)
			apply_paddle_physics(right, sub_dt)
			scored = update_ball(sub_dt, learn_enabled) or scored
		return scored


var brain := TinyPolicyNet.new(13, 24, 2)
var sim := PongSim.new(brain, true)
var warmup_done := 0
var player_active := false
var wheel: FFBWheel
var status_label: Label
var play_button: Button
var wheel_side_button: OptionButton
var steering_slider: HSlider
var damping_slider: HSlider
var steering_limit_deg := DEFAULT_STEERING_LIMIT_DEG
var wheel_range_deg := DEFAULT_WHEEL_RANGE_DEG
var wheel_half_sign := 1.0
var wheel_output_sign := -1.0
var wheel_status := "keyboard"
var ffb_suspended := false
var human_empty_timer := 0.0
var pulse_timer := 0.0
var pulse_remaining := 0


func _ready() -> void:
	randomize()
	_build_ui()
	_setup_ffb()
	run_pretrain()
	set_physics_process(true)


func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var top := HBoxContainer.new()
	top.anchor_right = 1.0
	top.offset_left = 14.0
	top.offset_top = 10.0
	top.offset_right = -14.0
	top.add_theme_constant_override("separation", 10)
	layer.add_child(top)

	play_button = Button.new()
	play_button.text = "Play left"
	play_button.pressed.connect(_toggle_player)
	top.add_child(play_button)

	var reset_button := Button.new()
	reset_button.text = "Reset + pretrain"
	reset_button.pressed.connect(run_pretrain)
	top.add_child(reset_button)

	wheel_side_button = OptionButton.new()
	wheel_side_button.add_item("Wheel inversion: CW up")
	wheel_side_button.add_item("Wheel inversion: CW down")
	wheel_side_button.item_selected.connect(_set_wheel_inversion)
	top.add_child(wheel_side_button)

	status_label = Label.new()
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.add_theme_font_size_override("font_size", 14)
	top.add_child(status_label)

	var bottom := HBoxContainer.new()
	bottom.anchor_left = 0.0
	bottom.anchor_top = 1.0
	bottom.anchor_right = 1.0
	bottom.anchor_bottom = 1.0
	bottom.offset_left = 14.0
	bottom.offset_top = -48.0
	bottom.offset_right = -14.0
	bottom.add_theme_constant_override("separation", 12)
	layer.add_child(bottom)

	bottom.add_child(_make_slider_label("limit deg"))
	steering_slider = _make_slider(20.0, 180.0, 1.0, steering_limit_deg)
	steering_slider.value_changed.connect(func(value: float): steering_limit_deg = value)
	bottom.add_child(steering_slider)

	bottom.add_child(_make_slider_label("damping"))
	damping_slider = _make_slider(0.0, 0.16, 0.005, HUMAN_IDLE_DAMPING)
	bottom.add_child(damping_slider)


func _make_slider_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.custom_minimum_size.x = 64.0
	return label


func _make_slider(min_value: float, max_value: float, step: float, value: float) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = min_value
	slider.max_value = max_value
	slider.step = step
	slider.value = value
	slider.custom_minimum_size.x = 180.0
	return slider


func _set_wheel_inversion(index: int) -> void:
	if index == 0:
		wheel_half_sign = 1.0
		wheel_output_sign = -1.0
		return

	wheel_half_sign = -1.0
	wheel_output_sign = 1.0


func _setup_ffb() -> void:
	wheel = FFBWheel.new()
	wheel.steering_range_deg = wheel_range_deg
	wheel.opened.connect(func(name: String): wheel_status = name)
	wheel.open_failed.connect(func(reason: String): wheel_status = "keyboard: " + reason)
	add_child(wheel)


func run_pretrain() -> void:
	_suspend_ffb()
	warmup_done = 0
	var training_sim := PongSim.new(brain, false)
	var dt := 1.0 / 120.0
	for episode in WARMUP_EPISODES:
		training_sim.reset_match(true)
		for step_index in WARMUP_MAX_STEPS:
			if training_sim.step(dt, true):
				break
		warmup_done += 1
	brain.traces.clear()
	sim = PongSim.new(brain, true)
	sim.reset_match(false)
	sim.human_left = player_active
	_resume_ffb()


func _suspend_ffb() -> void:
	ffb_suspended = true
	human_empty_timer = 0.0
	pulse_remaining = 0
	pulse_timer = 0.0
	if wheel != null and wheel.is_open():
		wheel.apply_torque(0.0)


func _resume_ffb() -> void:
	if wheel != null and wheel.is_open():
		wheel.poll(1.0 / 60.0)
		wheel.apply_torque(0.0)
	ffb_suspended = false


func _physics_process(delta: float) -> void:
	var dt := minf(delta, 1.0 / 30.0)
	_update_human_control(dt)
	_update_pulses(dt)
	if not sim.paused:
		sim.step(dt, true)
	_handle_game_ffb_events()
	_update_ffb(dt)
	_update_status()
	queue_redraw()


func _update_human_control(delta: float) -> void:
	var thrust := Input.get_axis("ui_up", "ui_down")
	var brake := 1.0 if Input.is_action_pressed("ui_accept") else 0.0
	if wheel.is_open():
		wheel.poll(delta)
		var angle := wheel.steering_angle_deg()
		var limit := maxf(1.0, steering_limit_deg)
		var half_angle := clampf(angle * wheel_half_sign, 0.0, limit)
		var center := limit * 0.5
		var deflection := clampf((half_angle - center) / center, -1.0, 1.0)
		var speed_limit := absf(deflection) * PADDLE_MAX_SPEED
		var velocity_room := clampf((speed_limit - absf(sim.left.vy)) / maxf(PADDLE_MAX_SPEED, 1.0), 0.0, 1.0)
		thrust = wheel_output_sign * deflection * velocity_room * HUMAN_ENGINE_IMPULSE / PADDLE_ACCEL
		brake = wheel.brake
	sim.human_control = {"thrust": clampf(thrust, -1.0, 1.0), "brake": clampf(brake, 0.0, 1.0)}


func _handle_game_ffb_events() -> void:
	if sim.last_event == "left_hit":
		_play_short_bump()
	if sim.last_event == "left_lost":
		human_empty_timer = HUMAN_LOSS_EMPTY_TIME
	if sim.last_event == "left_scored":
		_start_score_pulse()


func _update_ffb(delta: float) -> void:
	if not wheel.is_open():
		return
	if ffb_suspended:
		wheel.apply_torque(0.0)
		return
	human_empty_timer = maxf(0.0, human_empty_timer - delta)
	var steering := wheel.state.steering
	var damping := -damping_slider.value * wheel.state.steer_velocity
	var inertia_scale := 0.0 if human_empty_timer > 0.0 else HUMAN_INERTIA
	var inertia := -inertia_scale * clampf(sim.left.vy / PADDLE_MAX_SPEED, -1.0, 1.0)
	var limit_norm := steering_limit_deg / (wheel.steering_range_deg * 0.5)
	var virtual_center := wheel_half_sign * limit_norm * 0.5
	var centering := (virtual_center - steering) * HUMAN_CENTERING
	var soft_stop := 0.0
	var half_steering := steering * wheel_half_sign
	if half_steering < 0.0:
		soft_stop = wheel_half_sign * minf(1.0, absf(half_steering) * 16.0)
	if half_steering > limit_norm:
		soft_stop = -wheel_half_sign * minf(1.0, (half_steering - limit_norm) * 12.0)
	wheel.apply_torque(clampf(damping + inertia + centering + soft_stop, -1.0, 1.0))


func _play_short_bump() -> void:
	if wheel != null and wheel.is_open() and not ffb_suspended:
		wheel.play_curb()


func _start_score_pulse() -> void:
	pulse_remaining = 5
	pulse_timer = 0.001


func _update_pulses(delta: float) -> void:
	if pulse_remaining <= 0:
		return
	pulse_timer -= delta
	if pulse_timer > 0.0:
		return
	_play_short_bump()
	pulse_remaining -= 1
	pulse_timer = 0.16


func _toggle_player() -> void:
	player_active = not player_active
	sim.human_left = player_active
	play_button.text = "Bot left" if player_active else "Play left"


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.keycode:
		KEY_SPACE:
			_toggle_player()
		KEY_R:
			run_pretrain()
		KEY_P:
			sim.paused = not sim.paused
		KEY_C:
			if wheel.is_open():
				wheel.set_inverted(not wheel.inverted)


func _draw() -> void:
	var scale := minf(size.x / COURT_SIZE.x, size.y / COURT_SIZE.y)
	var offset := (size - COURT_SIZE * scale) * 0.5
	draw_set_transform(offset, 0.0, Vector2(scale, scale))
	_draw_court()
	_draw_paddle(sim.left, Color(0.45, 0.86, 1.0))
	_draw_paddle(sim.right, Color(1.0, 0.54, 0.81))
	_draw_ball()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_court() -> void:
	draw_rect(Rect2(Vector2.ZERO, COURT_SIZE), Color(0.02, 0.03, 0.08), true)
	draw_rect(Rect2(Vector2(18.0, 18.0), COURT_SIZE - Vector2(36.0, 36.0)), Color(1, 1, 1, 0.08), false, 2.0)
	for y in range(22, int(COURT_SIZE.y - 20.0), 24):
		draw_line(Vector2(COURT_SIZE.x * 0.5, y), Vector2(COURT_SIZE.x * 0.5, y + 10.0), Color(1, 1, 1, 0.14), 2.0)
	_draw_score_text(Vector2(COURT_SIZE.x * 0.5 - 82.0, 78.0), str(sim.left_score))
	_draw_score_text(Vector2(COURT_SIZE.x * 0.5 + 82.0, 78.0), str(sim.right_score))


func _draw_score_text(center_baseline: Vector2, text: String) -> void:
	var font := ThemeDB.fallback_font
	var text_width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, SCORE_FONT_SIZE).x
	draw_string(
		font,
		center_baseline - Vector2(text_width * 0.5, 0.0),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		SCORE_FONT_SIZE,
		Color(0.91, 0.93, 0.99, 0.9)
	)


func _draw_paddle(paddle: Paddle, color: Color) -> void:
	var intensity := minf(1.0, absf(paddle.vy) / PADDLE_MAX_SPEED)
	var rect := Rect2(Vector2(paddle.x, paddle.y), PADDLE_SIZE)
	draw_rect(rect.grow(3.0 + intensity * 4.0), Color(color.r, color.g, color.b, 0.09 + intensity * 0.08), true)
	draw_rect(rect, Color(color.r, color.g, color.b, 0.72 + intensity * 0.28), true)
	if absf(paddle.thrust) > 0.04:
		var thrust_y := paddle.y - 14.0 if paddle.thrust > 0.0 else paddle.y + PADDLE_SIZE.y
		draw_rect(Rect2(paddle.x - 2.0, thrust_y, PADDLE_SIZE.x + 4.0, 4.0 + absf(paddle.thrust) * 12.0), Color(1, 1, 1, 0.18), true)
	if paddle.brake > 0.08:
		draw_rect(Rect2(paddle.x - 4.0, paddle.y + 8.0, PADDLE_SIZE.x + 8.0, 5.0), Color(1, 1, 1, 0.12 + paddle.brake * 0.28), true)
		draw_rect(Rect2(paddle.x - 4.0, paddle.y + PADDLE_SIZE.y - 13.0, PADDLE_SIZE.x + 8.0, 5.0), Color(1, 1, 1, 0.12 + paddle.brake * 0.28), true)


func _draw_ball() -> void:
	draw_circle(Vector2(sim.ball.x, sim.ball.y), BALL_RADIUS + 8.0, Color(1, 1, 1, 0.08))
	draw_circle(Vector2(sim.ball.x, sim.ball.y), BALL_RADIUS, Color(0.96, 0.98, 1.0))
	draw_line(Vector2(sim.ball.x, sim.ball.y), Vector2(sim.ball.x - sim.ball.vx * 0.12, sim.ball.y - sim.ball.vy * 0.12), Color(1, 1, 1, 0.22), 1.0)


func _update_status() -> void:
	var mode := "human vs neural" if player_active else "neural self-play"
	var half_range := "0..+%.0f" % steering_limit_deg if wheel_half_sign > 0.0 else "0..-%.0f" % steering_limit_deg
	var cw_mapping := "CW up" if wheel_output_sign < 0.0 else "CW down"
	status_label.text = "%s | %s | brain %d | pretrain %d/%d | wheel %s | %s | %s deg | damping %.3f | torque %+.2f" % [
		mode,
		"paused" if sim.paused else "playing",
		brain.steps,
		warmup_done,
		WARMUP_EPISODES,
		wheel_status,
		cw_mapping,
		half_range,
		damping_slider.value,
		wheel.last_torque if wheel != null else 0.0
	]
