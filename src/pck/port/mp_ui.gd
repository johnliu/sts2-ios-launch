extends CanvasLayer
## iOS port: multiplayer join dialog (host IP entry) and hosting banner. Driven from C# (aot/Port/PortMultiplayer.cs).
## Built in _init so the C# side can call it before it has entered the tree.

signal join_submitted(ip: String)
signal cancelled
signal banner_action
signal banner_invite
signal pair_requested
signal choice_made(index: int)
signal code_submitted(code: String)

const GOLD := Color(0.95, 0.82, 0.45)
const ERROR_COLOR := Color(1.0, 0.6, 0.5)

var _font: Font
var _font_bold: Font
var _dialog: Control
var _message: Label
var _error: Label
var _ip: LineEdit
var _hosts_box: VBoxContainer
var _hosts_status: Label
var _hosts_title: Label
var _nearby_row: HBoxContainer
var _nearby_label: Label
var _nearby := false
var _banner: PanelContainer
var _banner_label: Label
var _banner_button: Button
var _banner_invite: Button
var _choice: Control
var _choice_title: Label
var _choice_text: Label
var _choice_buttons: HBoxContainer
var _code: Control
var _code_field: LineEdit
var _code_error: Label


func _init() -> void:
	layer = 115
	process_mode = Node.PROCESS_MODE_ALWAYS
	if ResourceLoader.exists("res://themes/kreon_regular_shared.tres"):
		_font = load("res://themes/kreon_regular_shared.tres")
	if ResourceLoader.exists("res://themes/kreon_bold_shared.tres"):
		_font_bold = load("res://themes/kreon_bold_shared.tres")
	var theme := Theme.new()
	theme.default_font_size = 28
	if _font != null:
		theme.default_font = _font

	# Join dialog: top-anchored so the landscape keyboard never covers the field.
	_dialog = Control.new()
	_dialog.theme = theme
	_dialog.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_dialog)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.78)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dialog.add_child(dim)
	var top := MarginContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.add_theme_constant_override("margin_top", 28)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dialog.add_child(top)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(Color(0.08, 0.09, 0.12, 0.97), GOLD, 3, 18, 30))
	panel.custom_minimum_size = Vector2(1180, 0)
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	panel.add_child(col)
	var title := Label.new()
	title.text = "Join a multiplayer game"
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", GOLD)
	if _font_bold != null:
		title.add_theme_font_override("font", _font_bold)
	col.add_child(title)
	_message = Label.new()
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message.custom_minimum_size = Vector2(1120, 0)
	_message.text = "Pick a game on your Wi-Fi below, or enter the host's IP address (a phone or iPad host shows " \
		+ "it at the top of its screen). A PC host must launch Slay the Spire 2 with --fastmp, then choose " \
		+ "Multiplayer > Host. When you're apart, use Tailscale."
	col.add_child(_message)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	col.add_child(row)
	_ip = LineEdit.new()
	_ip.placeholder_text = "Host IP, e.g. 192.168.1.20"
	_ip.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER_DECIMAL
	_ip.custom_minimum_size = Vector2(560, 76)
	_ip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ip.text_submitted.connect(func(_t): _submit())
	row.add_child(_ip)
	row.add_child(_button("Cancel", func():
		DisplayServer.virtual_keyboard_hide()
		cancelled.emit()))
	row.add_child(_button("Join", _submit))
	_error = Label.new()
	_error.add_theme_color_override("font_color", ERROR_COLOR)
	col.add_child(_error)
	# Games found on the network (set_hosts); below the field so the keyboard never covers it.
	_hosts_title = Label.new()
	_hosts_title.text = "Games on your Wi-Fi"
	_hosts_title.add_theme_font_size_override("font_size", 30)
	_hosts_title.add_theme_color_override("font_color", GOLD)
	if _font_bold != null:
		_hosts_title.add_theme_font_override("font", _font_bold)
	col.add_child(_hosts_title)
	_hosts_box = VBoxContainer.new()
	_hosts_box.add_theme_constant_override("separation", 10)
	col.add_child(_hosts_box)
	_hosts_status = Label.new()
	_hosts_status.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	_hosts_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hosts_status.custom_minimum_size = Vector2(1120, 0)
	col.add_child(_hosts_status)
	# Wi-Fi Aware (set_nearby): phones in the same room play without a Wi-Fi network once paired.
	_nearby_row = HBoxContainer.new()
	_nearby_row.add_theme_constant_override("separation", 18)
	_nearby_label = Label.new()
	_nearby_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_nearby_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_nearby_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_nearby_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	_nearby_row.add_child(_nearby_label)
	_nearby_row.add_child(_button("Pair a phone", func():
		DisplayServer.virtual_keyboard_hide()
		pair_requested.emit()))
	_nearby_row.visible = false
	col.add_child(_nearby_row)
	set_hosts([])
	_dialog.visible = false

	# How to host or join (show_choice): nearby and on the Wi-Fi, or with an invite code.
	_choice = _panel(theme)
	var choice_col: VBoxContainer = _choice.get_meta("col")
	_choice_title = choice_col.get_child(0) as Label
	_choice_text = choice_col.get_child(1) as Label
	_choice_buttons = HBoxContainer.new()
	_choice_buttons.add_theme_constant_override("separation", 18)
	choice_col.add_child(_choice_buttons)
	add_child(_choice)
	_choice.visible = false

	# Invite code entry (show_code).
	_code = _panel(theme)
	var code_col: VBoxContainer = _code.get_meta("col")
	(code_col.get_child(0) as Label).text = "Join with an invite code"
	(code_col.get_child(1) as Label).text = "Ask the host to tap Copy invite code and send it to you (Messages works), then " \
		+ "copy it and tap Paste."
	_code_field = LineEdit.new()
	_code_field.placeholder_text = "Invite code (starts with tc)"
	_code_field.custom_minimum_size = Vector2(1120, 76)
	_code_field.text_submitted.connect(func(_t): _submit_code())
	code_col.add_child(_code_field)
	_code_error = Label.new()
	_code_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_code_error.custom_minimum_size = Vector2(1120, 0)
	code_col.add_child(_code_error)
	var code_row := HBoxContainer.new()
	code_row.add_theme_constant_override("separation", 18)
	code_row.alignment = BoxContainer.ALIGNMENT_END
	code_row.add_child(_button("Cancel", func():
		DisplayServer.virtual_keyboard_hide()
		cancelled.emit()))
	code_row.add_child(_button("Paste", func(): _code_field.text = DisplayServer.clipboard_get().strip_edges()))
	code_row.add_child(_button("Join", _submit_code))
	code_col.add_child(code_row)
	add_child(_code)
	_code.visible = false

	# Hosting banner.
	_banner = PanelContainer.new()
	_banner.add_theme_stylebox_override("panel", _box(Color(0.05, 0.06, 0.08, 0.88), Color(GOLD, 0.6), 2, 14, 12))
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner_label = Label.new()
	_banner_label.add_theme_font_size_override("font_size", 24)
	if _font_bold != null:
		_banner_label.add_theme_font_override("font", _font_bold)
	var banner_content := HBoxContainer.new()
	banner_content.add_theme_constant_override("separation", 18)
	banner_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.add_child(banner_content)
	_banner_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	banner_content.add_child(_banner_label)
	_banner_button = _button("", func(): banner_action.emit())
	_banner_button.custom_minimum_size = Vector2(150, 56)
	_banner_button.add_theme_font_size_override("font_size", 24)
	_banner_button.theme = Theme.new()
	if _font != null:
		_banner_button.theme.default_font = _font
	banner_content.add_child(_banner_button)
	_banner_invite = _button("", func(): banner_invite.emit())
	_banner_invite.custom_minimum_size = _banner_button.custom_minimum_size
	_banner_invite.add_theme_font_size_override("font_size", 24)
	_banner_invite.theme = _banner_button.theme
	banner_content.add_child(_banner_invite)
	var banner_row := CenterContainer.new()
	banner_row.set_anchors_preset(Control.PRESET_TOP_WIDE)
	banner_row.position.y = 14
	banner_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner_row.add_child(_banner)
	add_child(banner_row)
	_banner.visible = false


## A dialog like the join one: dimmed screen, top-anchored panel with a title and a message (meta "col": its column).
func _panel(theme: Theme) -> Control:
	var root := Control.new()
	root.theme = theme
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.78)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)
	var top := MarginContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top.add_theme_constant_override("margin_top", 28)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(top)
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(Color(0.08, 0.09, 0.12, 0.97), GOLD, 3, 18, 30))
	panel.custom_minimum_size = Vector2(1180, 0)
	center.add_child(panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 16)
	panel.add_child(col)
	var title := Label.new()
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", GOLD)
	if _font_bold != null:
		title.add_theme_font_override("font", _font_bold)
	col.add_child(title)
	var text := Label.new()
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.custom_minimum_size = Vector2(1120, 0)
	col.add_child(text)
	root.set_meta("col", col)
	return root


func _submit_code() -> void:
	var code := _code_field.text.strip_edges()
	if not code.begins_with("tc") or code.length() < 20:
		_code_error.add_theme_color_override("font_color", ERROR_COLOR)
		_code_error.text = "That isn't an invite code. Copy the whole code the host sent (it starts with tc)."
		return
	DisplayServer.virtual_keyboard_hide()
	code_submitted.emit(code)


## Two or more ways to go on, plus Cancel: emits choice_made with the option's index, or -1.
func show_choice(title: String, text: String, options: Array) -> void:
	_choice_title.text = title
	_choice_text.text = text
	for child in _choice_buttons.get_children():
		child.queue_free()
	for i in options.size():
		var index := i
		var b := _button(options[i], func():
			_choice.visible = false
			choice_made.emit(index))
		b.custom_minimum_size = Vector2(380, 76)
		_choice_buttons.add_child(b)
	_choice_buttons.add_child(_button("Cancel", func():
		_choice.visible = false
		choice_made.emit(-1)))
	_dialog.visible = false
	_code.visible = false
	_choice.visible = true


## The invite code dialog; error: why the last code didn't work (or "").
func show_code(error: String) -> void:
	var clip := DisplayServer.clipboard_get().strip_edges()
	if _code_field.text == "" and clip.begins_with("tc"):
		_code_field.text = clip
	_code_error.add_theme_color_override("font_color", ERROR_COLOR)
	_code_error.text = error
	_dialog.visible = false
	_choice.visible = false
	_code.visible = true


func _box(bg: Color, border: Color, border_width: int, radius: int, margin: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.border_color = border
	box.set_border_width_all(border_width)
	box.set_corner_radius_all(radius)
	box.content_margin_left = margin + 8
	box.content_margin_right = margin + 8
	box.content_margin_top = margin
	box.content_margin_bottom = margin
	return box


func _button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(200, 76)
	for state in ["normal", "hover", "pressed"]:
		b.add_theme_stylebox_override(state, _box(Color(0.16, 0.17, 0.22) if state != "pressed" else Color(0.3, 0.26, 0.14), Color(GOLD, 0.8), 2, 12, 6))
	b.pressed.connect(on_press)
	return b


func _submit() -> void:
	DisplayServer.virtual_keyboard_hide()
	join_submitted.emit(_ip.text.strip_edges())


func show_join(ip: String, error: String) -> void:
	_ip.text = ip
	_error.add_theme_color_override("font_color", ERROR_COLOR)
	_error.text = error
	_error.visible = error != ""
	_dialog.visible = true


## hosts: [{ip, title, detail, joinable}], as found by PortDiscovery (aot/Port/PortDiscovery.cs).
func set_hosts(hosts: Array) -> void:
	for child in _hosts_box.get_children():
		child.queue_free()
	for host in hosts:
		var ip: String = host["ip"]
		var b := _button("%s   ·   %s" % [host["title"], host["detail"]], func():
			DisplayServer.virtual_keyboard_hide()
			join_submitted.emit(ip))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.disabled = not host["joinable"]
		if b.disabled:
			b.modulate = Color(1, 1, 1, 0.5)
		_hosts_box.add_child(b)
	if _nearby:
		_hosts_status.text = "Looking for games… The host needs Multiplayer > Host open, nearby or on the same Wi-Fi."
	else:
		_hosts_status.text = "Looking for games… The host needs Multiplayer > Host open, on the same Wi-Fi."
	_hosts_status.visible = hosts.is_empty()


## A progress line where errors go (e.g. "Connecting to …"), in a neutral color.
func show_note(text: String) -> void:
	if _code.visible:
		_code_error.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
		_code_error.text = text
		return
	_error.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	_error.text = text
	_error.visible = text != ""


## supported: this phone can play nearby over Wi-Fi Aware (aot/Port/PortNearby.cs); paired: phones paired with it.
func set_nearby(supported: bool, paired: int) -> void:
	_nearby = supported
	_nearby_row.visible = supported
	_hosts_title.text = "Games nearby and on your Wi-Fi" if supported else "Games on your Wi-Fi"
	if paired == 0:
		_nearby_label.text = "In the same room with no Wi-Fi? Pair your phones once, then the host's game shows up here."
	else:
		_nearby_label.text = "Paired phones that host show up here, even without Wi-Fi. Pair another phone:"


func close_join() -> void:
	DisplayServer.virtual_keyboard_hide()
	_dialog.visible = false
	_choice.visible = false
	_code.visible = false


## action: optional button text (e.g. "Cancel"); pressing it emits banner_action. invite_action: likewise for
## banner_invite.
func show_banner(text: String, action: String = "", invite_action: String = "") -> void:
	_banner_label.text = text
	_banner_button.text = action
	_banner_button.visible = action != ""
	_banner_invite.text = invite_action
	_banner_invite.visible = invite_action != ""
	_banner.visible = true


func hide_banner() -> void:
	_banner.visible = false
