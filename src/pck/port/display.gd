extends Node
## iOS port: full-bleed widescreen (no pillarbox) and a larger UI.
## The game re-applies its own aspect-ratio setting (Keep 16:9 by default), so this is enforced every frame.

const UI_HEIGHT := 960 # logical canvas height; game default 1080 -> lower = bigger UI (960 = +12.5%)
const MIN_WIDTH := 1680 # same minimum width the game uses for its own "Auto" (Expand) mode
const DESIGN_HEIGHT := 1080.0 # canvas height the game's hard-coded positions assume
const HAND_RAISE := 64.0 # canvas units the hand is lifted so card drags start above the iOS home-swipe zone
const STAR_SHIFT := Vector2(-34, -4) # Regent star counter moved off the energy orb (the PC layout overlaps them)
const DEBUG_SHOTS := false # saves user://port_shots/auto_NN.jpg every SHOT_INTERVAL seconds
# Runtime switch: if user://port_debug_shots exists, take as many shots as the number it contains
# (default 5), then delete it. Push it with `devicectl device copy to` -- no rebuild needed.
const SHOT_FLAG := "user://port_debug_shots"
const SHOT_INTERVAL := 4.0

# UI containers pulled inside the iOS safe area (rounded corners / Dynamic Island) while backgrounds stay
# full-bleed. Key = node name, value = required parent name ("" = any).
const INSET_TARGETS := {
	"LeftAlignedStuff": "TopBar",
	"RightAlignedStuff": "TopBar",
	"RelicInventory": "GlobalUi",
	"MultiplayerPlayerContainer": "GlobalUi",
	"DebugInfo": "GlobalUi",
	"EnergyCounterContainer": "CombatUi",
	"StarCounter": "CombatUi",
	"CombatPileContainer": "CombatUi",
	"ChangeProfileButton": "MainMenu",
	"PatchNotesButton": "MainMenu",
	"ReleaseInfo": "MainMenu",
	"ModdedWarning": "MainMenu",
	"ModWarningContainer": "MainMenu",
	"DrawingTools": "", # map screen draw/erase/clear, bottom-left
}
# NEndTurnButton places itself at a fixed fraction of the viewport width (1604/1920), so it is
# pulled in by the inset right before drawing (after tweens have run).
const END_TURN_X_RATIO := 1604.0 / 1920.0
const BACK_HIDE_OFFSET := Vector2(-180, 0) # NBackButton._hideOffset
# Nodes the game tweens to absolute y positions designed for a 1080-tall canvas. Key = node name,
# value = script file of the scene root that owns it. Clamped so their bottom stays on screen.
const BOTTOM_CLAMP := {
	"AcknowledgeButton": ["NTimelineTutorial.cs"],
	"Description": ["NRestSiteRoom.cs", "NBestiary.cs"],
}

# Combat scene (background + creatures). The game stands creatures 200 units below the screen centre of a 1080-tall
# canvas and anchors the hand to the bottom; on our shorter canvas, with the hand raised, the resting hand would
# cover HP bars. The scene is lifted to keep the PC gap, shrunk around the HP-bar line if tall creatures or intents
# would then reach the top bar, and the background is enlarged if it would no longer cover the screen.
const SCENE_PIVOT_BELOW_CENTER := 240.0 # creatures stand 200 below the centre; HP bars and powers sit just below
const SCENE_MIN_SCALE := 0.7
const SCENE_TOP_MARGIN := 8.0
const SCENE_SNAP_MS := 1500 # settle the layout instantly while the room fades in, then animate
const BG_COVER_MARGIN := 30.0 # past the screen edges, so screen shake doesn't reveal them
const BG_MAX_SCALE := 1.8
const BG_FLOOR := Vector2(0, 200) # background point creatures stand on; enlarging around it keeps them on the floor

# Card inspect screen (tap a card in a deck view): the game shows the card at 1.75x with "View Upgrades" 450-514 below
# the centre, laid out for a 1080-tall canvas, so on ours the toggle ends below the screen. Shrink the card just enough
# and move it up so card and toggle fit above the home indicator.
const INSPECT_SCALE := 1.75 # NInspectCardScreen.Open
const INSPECT_TOP := 12.0 # space above the energy gem
const INSPECT_GEM := 15.0 # the cost gem sticks out this far above the card frame (at scale 1)
const INSPECT_GAP := 20.0 # card bottom to toggle

# Act banner ("Act 1" over "Underdocks" when an act starts): NActBanner tweens the act number to y 440-450, just above
# the act name on a 1080-tall canvas. On ours the name sits 60 higher and covered the number, so the number follows the
# game's tween moved up by the same amount (_fix_act_banners).

var _scene: Control = null # NCombatRoom's CombatSceneContainer
var _shake: Node = null # NScreenShake: re-applies the scene's base position every frame
var _top_row: Control = null # TopBar/LeftAlignedStuff
var _relics: Control = null
var _scene_base := Vector2.INF # the game's base position for the scene (incl. its camera offset)
var _scene_scale := 1.0 # the game's camera scaling for the encounter
var _scene_k := 1.0 # our extra scale (<= 1) so tall content stays below the top bar
var _scene_since := 0
var _scene_logged := false
var _bg_node: Node = null
var _bg_cover := Rect2() # BgContainer-local rect every full-screen background layer covers
var _inspect: Control = null # NInspectCardScreen
var _act_banners: Array[Control] = [] # NActBanner
var _piles: Array[Control] = [] # combat draw/discard/exhaust pile buttons
var _hand_box: Control = null # NPlayerHand's CardHolderContainer
var _hand_k := 1.0 # our scale for it
var _hand_shift := 0.0 # and horizontal shift, canvas units
var _hand_card_half := 0.0 # half a card's width at scale 1, measured from the first card seen
var _hand_logged := ""
var _hand_room := Vector2(-INF, INF) # widest HUD extents seen (the energy orb pulses), reset per combat and canvas
var _hand_room_for := ""

# Safe-area insets in logical canvas units. Each side on its own: on an iPhone Duo's outer screen the camera and
# status column is on one side only, and turning the phone over moves it to the other.
var _inset_left := 0.0
var _inset_right := 0.0
var _last_safe := Rect2i()
var _targets: Array[Control] = []
var _back_buttons: Array[Control] = [] # NBackButton: slides between _showPos/_hidePos (set in its _Ready)
var _end_turn_buttons: Array[Control] = []
var _bottom_clamped: Array[Control] = []
var _bottom_margin := 0.0 # logical units kept clear above the home indicator
var _shots_left := -1 # -1 = unlimited (DEBUG_SHOTS), 0 = off
var _since_shot := 0.0
var _shot_index := 0
var _last_rect := Rect2()
var _background: Node = null # background_res.gd: the combat background at its art's resolution


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_shots_left = -1 if DEBUG_SHOTS else 0
	if FileAccess.file_exists(SHOT_FLAG):
		var n := FileAccess.get_file_as_string(SHOT_FLAG).strip_edges().to_int()
		_shots_left = n if n > 0 else 5
		DirAccess.remove_absolute(SHOT_FLAG)
	_enforce() # computes the insets before any game UI is added
	# Connected before any game node: on a resize (an iPhone Duo opening or closing) the content scale size is
	# updated before the game's own size_changed handlers read it.
	get_tree().root.size_changed.connect(_enforce)
	get_tree().node_added.connect(_on_node_added)
	RenderingServer.frame_pre_draw.connect(_before_draw)
	_background = preload("res://port/background_res.gd").new()
	add_child(_background)


func _on_node_added(node: Node) -> void:
	var node_scr: Script = node.get_script()
	if node_scr != null and node_scr.resource_path.get_file() == "NScreenShake.cs":
		_shake = node
	if not (node is Control):
		return
	var parent := node.get_parent()
	if String(node.name) == "CombatSceneContainer" and node.owner != null:
		var room_scr: Script = node.owner.get_script()
		if room_scr != null and room_scr.resource_path.get_file() == "NCombatRoom.cs":
			_scene = node as Control
			_scene_base = Vector2.INF
			_scene_k = 1.0
			_scene_logged = false
			return
	if String(node.name) == "LeftAlignedStuff" and parent != null and String(parent.name) == "TopBar":
		_top_row = node as Control
	elif String(node.name) == "RelicInventory":
		_relics = node as Control
	if parent is Control and String(parent.name) == "EnergyCounterContainer":
		# NCombatUi.Activate adds the energy counter right after (maybe) moving this container and right before
		# reparenting the star counter onto it, so fix the container now.
		_restore_bottom_anchor(parent as Control)
	if String(node.name) == "StarCounter" and parent != null and parent.get_parent() != null \
			and String(parent.get_parent().name) == "EnergyCounterContainer":
		# Reparented onto the energy counter; Reparent restores its global position after this signal.
		_shift_star.call_deferred(node)
	if String(node.name) == "CardHolderContainer" and node.owner != null:
		var hand_scr: Script = node.owner.get_script()
		if hand_scr != null and hand_scr.resource_path.get_file() == "NPlayerHand.cs":
			var holder := node as Control
			if not holder.has_meta("port_orig_y"):
				holder.set_meta("port_orig_y", Vector2(holder.offset_top, holder.offset_bottom))
			var orig_y: Vector2 = holder.get_meta("port_orig_y")
			holder.offset_top = orig_y.x - HAND_RAISE
			holder.offset_bottom = orig_y.y - HAND_RAISE
			if not holder.has_meta("port_orig_x"):
				holder.set_meta("port_orig_x", Vector2(holder.offset_left, holder.offset_right))
			_hand_box = holder
			_hand_k = 1.0
			_hand_shift = 0.0
			return
	var scr: Script = node.get_script()
	if scr != null:
		match scr.resource_path.get_file():
			"NBackButton.cs":
				_back_buttons.append(node as Control)
				return
			"NEndTurnButton.cs":
				_end_turn_buttons.append(node as Control)
				return
			"NInspectCardScreen.cs":
				_inspect = node as Control
				return
			"NActBanner.cs":
				_act_banners.append(node as Control)
				return
			"NDrawPileButton.cs", "NDiscardPileButton.cs", "NExhaustPileButton.cs":
				_piles.append(node as Control)
				return
			"NMainMenu.cs":
				node.ready.connect(_hide_quit.bind(node), CONNECT_ONE_SHOT)
	if BOTTOM_CLAMP.has(String(node.name)) and node.owner != null:
		var owner_scr: Script = node.owner.get_script()
		if owner_scr != null and owner_scr.resource_path.get_file() in BOTTOM_CLAMP[String(node.name)]:
			_bottom_clamped.append(node as Control)
		return
	if not INSET_TARGETS.has(String(node.name)):
		return
	var parent_name: String = INSET_TARGETS[String(node.name)]
	if parent_name != "" and (node.get_parent() == null or String(node.get_parent().name) != parent_name):
		return
	var c := node as Control
	if not c.has_meta("port_orig"):
		c.set_meta("port_orig", Vector2(c.offset_left, c.offset_right))
	_targets.append(c)
	# Apply now, before children run _Ready (some cache their positions there, e.g. the pile buttons).
	_inset_control(c)


# NCombatUi.Activate (Regent only) calls EnergyCounterContainer.SetPosition((100, 806), keepOffsets) -- a point on a
# 1080-tall canvas, applied by moving the anchors. Turn it back into a bottom-left anchored point at the same
# distance from the bottom, keeping the safe-area inset.
func _restore_bottom_anchor(c: Control) -> void:
	if is_equal_approx(c.anchor_left, 0.0) and is_equal_approx(c.anchor_top, 1.0) \
			and is_equal_approx(c.anchor_right, 0.0) and is_equal_approx(c.anchor_bottom, 1.0):
		return
	var p := c.position
	var sz := c.size
	c.anchor_left = 0.0
	c.anchor_right = 0.0
	c.anchor_top = 1.0
	c.anchor_bottom = 1.0
	c.set_meta("port_orig", Vector2(p.x, p.x + sz.x))
	c.offset_top = p.y - DESIGN_HEIGHT
	c.offset_bottom = c.offset_top + sz.y
	_inset_control(c)


func _shift_star(star: Control) -> void:
	if is_instance_valid(star) and not star.has_meta("port_star_shifted"):
		star.set_meta("port_star_shifted", true)
		star.position += STAR_SHIFT


func _edge_delta(anchor: float) -> float:
	# Left-anchored edges move right, right-anchored edges move left, centred edges stay.
	if anchor < 0.4:
		return _inset_left
	if anchor > 0.6:
		return -_inset_right
	return 0.0


func _inset_control(c: Control) -> void:
	var orig: Vector2 = c.get_meta("port_orig")
	var left := orig.x + _edge_delta(c.anchor_left)
	var right := orig.y + _edge_delta(c.anchor_right)
	if not is_equal_approx(c.offset_left, left) or not is_equal_approx(c.offset_right, right):
		c.offset_left = left
		c.offset_right = right


# Lifts/shrinks the combat scene (see SCENE_* above). Positions are in the scene's parent space. The game's layout is
# "base" (its camera offset applied) at its camera scaling s0; ours moves it up by `lift`, then scales it by k around
# the HP-bar line. NScreenShake re-applies its saved base position every frame, so that is what gets changed.
func _layout_combat() -> void:
	if _scene == null:
		return
	if not is_instance_valid(_scene) or not _scene.is_inside_tree():
		_scene = null
		return
	if _scene.owner == null or not _scene.owner.is_node_ready():
		return
	if _shake == null or not is_instance_valid(_shake):
		_shake = _find_shake()
	var shaken: bool = _shake != null and _shake.get("ShakeTarget") == _scene
	if _scene_base == Vector2.INF:
		_scene_base = _shake.get("_originalTargetPosition") if shaken else _scene.position
		_scene_scale = _scene.scale.x
		_scene_since = Time.get_ticks_msec()
	var lift := maxf(0.0, (DESIGN_HEIGHT - get_viewport().get_visible_rect().size.y) * 0.5 + HAND_RAISE)
	var p0 := _scene.pivot_offset
	var s0 := _scene_scale
	var base := _scene_base - Vector2(0, lift)
	var q := Vector2(_scene.size.x * 0.5, _scene.size.y * 0.5 + SCENE_PIVOT_BELOW_CENTER)
	var k_target := _fit_scale(base, p0, s0, base + p0 + s0 * (q - p0))
	if Time.get_ticks_msec() - _scene_since < SCENE_SNAP_MS:
		_scene_k = k_target
	elif k_target < _scene_k:
		_scene_k = maxf(k_target, _scene_k - 0.01) # only ever shrinks, so intents coming and going don't pump it
	var s1 := s0 * _scene_k
	var pos := base + (1.0 - _scene_k) * s0 * (q - p0) # keeps the HP-bar line where it is when scaling
	if shaken:
		var saved: Vector2 = _shake.get("_originalTargetPosition")
		if not saved.is_equal_approx(pos):
			_shake.set("_originalTargetPosition", pos)
			_scene.position += pos - saved # keep the current shake offset; takes effect this frame
	elif not _scene.position.is_equal_approx(pos):
		_scene.position = pos
	if not is_equal_approx(_scene.scale.x, s1):
		_scene.scale = Vector2(s1, s1)
	_cover_background(pos, p0, s1)
	if not _scene_logged and Time.get_ticks_msec() - _scene_since >= SCENE_SNAP_MS:
		_scene_logged = true
		var bgc := _scene.get_node_or_null("BgContainer") as Control
		print("[PORT] combat scene: camera ", s0, " lift ", lift, " fit ", snappedf(_scene_k, 0.001), " shake ", shaken,
			" background x", snappedf(bgc.scale.x if bgc != null else 1.0, 0.001))


func _find_shake() -> Node:
	for n in get_tree().root.find_children("ScreenShake", "", true, false):
		var s: Script = n.get_script()
		if s != null and s.resource_path.get_file() == "NScreenShake.cs":
			return n
	return null


static func _global_rect(c: Control) -> Rect2:
	var xf := c.get_global_transform()
	var a := xf * Vector2.ZERO
	var b := xf * c.size
	return Rect2(a.min(b), (b - a).abs())


# Largest scale (<= 1) at which every creature's hitbox and intents stay below the top bar (and below the relic row
# where they overlap it), measured in the lifted, unscaled layout.
func _fit_scale(base: Vector2, p0: Vector2, s0: float, pivot: Vector2) -> float:
	var to_parent := (_scene.get_parent() as CanvasItem).get_global_transform().affine_inverse()
	var to_scene := _scene.get_global_transform().affine_inverse()
	var top_limit := (_global_rect(_top_row).end.y if is_instance_valid(_top_row) else 80.0) + SCENE_TOP_MARGIN
	var relic_rect := Rect2()
	if is_instance_valid(_relics) and _relics.is_visible_in_tree():
		for holder in _relics.get_children():
			if holder is Control and holder.visible:
				var r := _global_rect(holder)
				relic_rect = r if not relic_rect.has_area() else relic_rect.merge(r)
	var k := 1.0
	for container_name in ["AllyContainer", "EnemyContainer"]:
		var container := _scene.get_node_or_null(container_name)
		if container == null:
			continue
		for creature in container.get_children():
			if not (creature is Control) or not creature.is_visible_in_tree():
				continue
			var hitbox := creature.get_node_or_null("Hitbox") as Control
			if hitbox == null:
				continue
			var rect := _global_rect(hitbox)
			var intents := creature.get_node_or_null("Intents") as Control
			if intents != null:
				for icon in intents.get_children():
					if icon is Control and icon.visible:
						rect = rect.merge(_global_rect(icon))
			var a := to_scene * rect.position
			var b := to_scene * rect.end
			var top := base.y + p0.y + s0 * (minf(a.y, b.y) - p0.y)
			var left := base.x + p0.x + s0 * (minf(a.x, b.x) - p0.x)
			var right := base.x + p0.x + s0 * (maxf(a.x, b.x) - p0.x)
			var limit := top_limit
			if relic_rect.has_area() and right > relic_rect.position.x and left < relic_rect.end.x:
				limit = maxf(limit, relic_rect.end.y + SCENE_TOP_MARGIN)
			limit = (to_parent * Vector2(0, limit)).y
			if top < limit and pivot.y - top > 1.0:
				k = minf(k, (pivot.y - limit) / (pivot.y - top))
	return clampf(k, SCENE_MIN_SCALE, 1.0)


# Scales the background around the floor line just enough to keep covering the screen (plus a shake margin) after
# the scene was moved and scaled. Most encounters need no change; zoomed-out bosses can.
func _cover_background(pos: Vector2, p0: Vector2, s1: float) -> void:
	var bgc := _scene.get_node_or_null("BgContainer") as Control
	if bgc == null or bgc.get_child_count() == 0:
		return
	var bg := bgc.get_child(0)
	if bg != _bg_node:
		_bg_node = bg
		_bg_cover = _background_cover(bgc, bg)
	if not _bg_cover.has_area():
		return
	var to_parent := (_scene.get_parent() as CanvasItem).get_global_transform().affine_inverse()
	var tl := to_parent * Vector2.ZERO
	var br := to_parent * get_viewport().get_visible_rect().size
	if bgc.pivot_offset != BG_FLOOR:
		bgc.pivot_offset = BG_FLOOR
	var c := pos + p0 + s1 * (bgc.position + BG_FLOOR - p0) # the floor point in parent space
	var r := Rect2(_bg_cover.position - BG_FLOOR, _bg_cover.size) # cover rect relative to the floor point
	var m := BG_COVER_MARGIN
	var f := 1.0
	if r.position.x < 0:
		f = maxf(f, (c.x - tl.x + m) / (s1 * -r.position.x))
	if r.end.x > 0:
		f = maxf(f, (br.x + m - c.x) / (s1 * r.end.x))
	if r.position.y < 0:
		f = maxf(f, (c.y - tl.y + m) / (s1 * -r.position.y))
	if r.end.y > 0:
		f = maxf(f, (br.y + m - c.y) / (s1 * r.end.y))
	f = minf(f, BG_MAX_SCALE)
	if not is_equal_approx(bgc.scale.x, f):
		bgc.scale = Vector2(f, f)


# Intersection of the largest image of each full-screen layer (Layer_NN / Foreground), in BgContainer-local units.
static func _background_cover(bgc: Control, bg: Node) -> Rect2:
	var to_local := bgc.get_global_transform().affine_inverse()
	var cover := Rect2()
	for layer in bg.get_children():
		var layer_name := String(layer.name)
		if not (layer_name.begins_with("Layer_") or layer_name == "Foreground"):
			continue
		var best := Rect2()
		for tr in layer.find_children("*", "TextureRect", true, false):
			var xf: Transform2D = to_local * (tr as Control).get_global_transform()
			var a := xf * Vector2.ZERO
			var b := xf * (tr as Control).size
			var r := Rect2(a.min(b), (b - a).abs())
			if r.get_area() > best.get_area():
				best = r
		if best.size.x >= 2000.0 and best.size.y >= 1000.0:
			cover = best if not cover.has_area() else cover.intersection(best)
	return cover


func _before_draw() -> void:
	_layout_combat()
	_fit_hand()
	_fix_piles()
	_fit_inspect()
	_fix_act_banners()
	var vis := get_viewport().get_visible_rect().size
	var vw := vis.x
	var j := _bottom_clamped.size() - 1
	while j >= 0:
		var c := _bottom_clamped[j]
		if not is_instance_valid(c) or not c.is_inside_tree():
			_bottom_clamped.remove_at(j)
		elif c.is_visible_in_tree():
			var h := c.size.y * c.get_global_transform().get_scale().y
			var max_y := vis.y - _bottom_margin - h
			if c.global_position.y > max_y:
				c.global_position.y = max_y
		j -= 1
	var i := _end_turn_buttons.size() - 1
	while i >= 0:
		var b := _end_turn_buttons[i]
		if not is_instance_valid(b) or not b.is_inside_tree():
			_end_turn_buttons.remove_at(i)
		else:
			var x := END_TURN_X_RATIO * vw - _inset_right
			if not is_equal_approx(b.position.x, x):
				b.position.x = x
		i -= 1
	_background.before_draw() # last: it follows the background to where the layout above put it


# Hand of cards on squarer screens (an iPhone Duo; the canvas is MIN_WIDTH wide): the game spreads cards at fixed
# offsets from the bottom centre (HandPosHelper), so with the safe-area insets the fan ran into the energy orb or the
# End Turn button. Keep it between them: shift it as little as needed, then shrink it (down to HAND_MIN_SCALE).
# Wide phones keep the game's layout.
const HAND_X_EXTENT := [0.0, 100.0, 180.0, 240.0, 340.0, 460.0, 534.0, 565.0, 600.0, 610.0] # outermost card centre
const HAND_GAP := 12.0 # canvas units kept clear between the hand and the HUD on either side
const HAND_TILT_MARGIN := 20.0 # outer cards are tilted, so their corners reach a little further
const HAND_MIN_SCALE := 0.7

func _fit_hand() -> void:
	if _hand_box == null:
		return
	if not is_instance_valid(_hand_box) or not _hand_box.is_inside_tree():
		_hand_box = null
		return
	var vis := get_viewport().get_visible_rect().size
	var k := 1.0
	var shift := 0.0
	var holders := _hand_box.get_children().filter(func(h): return h is Control)
	var n := mini(holders.size(), HAND_X_EXTENT.size())
	var ui := _hand_box.get_parent().get_parent() if _hand_box.get_parent() != null else null
	if vis.x <= MIN_WIDTH + 1.0 and n > 0 and ui != null and _hand_box.is_visible_in_tree():
		if _hand_card_half <= 0.0:
			for c in (holders[0] as Control).get_children():
				if c is Control and (c as Control).size.x > 50.0:
					_hand_card_half = (c as Control).size.x * 0.5 * absf((c as Control).scale.x)
					print("[PORT] hand: card half-width ", _hand_card_half)
					break
		var card_scale := 0.8 * ([1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 0.95, 0.9, 0.85][n - 1] as float)
		var half: float = HAND_X_EXTENT[n - 1] + (_hand_card_half if _hand_card_half > 0.0 else 150.0) * card_scale \
			+ HAND_TILT_MARGIN
		var left := 0.0
		var right := vis.x
		var energy := ui.get_node_or_null("EnergyCounterContainer") as Control
		if energy != null:
			left = maxf(left, _visible_extent(energy, true))
		var end_turn := ui.get_node_or_null("EndTurnButton") as Control
		if end_turn != null and end_turn.is_visible_in_tree():
			right = minf(right, _global_rect(end_turn).position.x)
		var piles := ui.get_node_or_null("CombatPileContainer")
		if piles != null:
			for pile_name in ["DrawPile", "DiscardPile", "ExhaustPile"]:
				var pile := piles.get_node_or_null(pile_name) as Control
				if pile != null and pile.is_visible_in_tree():
					var r := _global_rect(pile)
					if r.get_center().x < vis.x * 0.5:
						left = maxf(left, r.end.x)
					else:
						right = minf(right, r.position.x)
		var room_for := "%s %s %s" % [_hand_box.get_instance_id(), vis, _last_safe]
		if room_for != _hand_room_for:
			_hand_room_for = room_for
			_hand_room = Vector2(-INF, INF)
		_hand_room = Vector2(maxf(_hand_room.x, left), minf(_hand_room.y, right))
		left = _hand_room.x
		right = _hand_room.y
		var avail := right - left - 2.0 * HAND_GAP
		k = clampf(avail / (2.0 * half), HAND_MIN_SCALE, 1.0)
		var lo := left + HAND_GAP + half * k - vis.x * 0.5 # allowed range for the shift
		var hi := right - HAND_GAP - half * k - vis.x * 0.5
		shift = clampf(0.0, lo, hi) if lo <= hi else (lo + hi) * 0.5
		var key := "%d %.2f %.0f" % [n, snappedf(k, 0.05), snappedf(shift, 20.0)]
		if key != _hand_logged:
			_hand_logged = key
			print("[PORT] hand: %d cards, room %.0f-%.0f -> scale %.2f shift %.0f" % [n, left, right, k, shift])
	# Ease towards the target (drawn and played cards change it), quickly enough to follow the game's own tweens.
	var step := 0.25
	_hand_k = k if absf(_hand_k - k) < 0.002 else lerpf(_hand_k, k, step)
	_hand_shift = shift if absf(_hand_shift - shift) < 0.5 else lerpf(_hand_shift, shift, step)
	if not is_equal_approx(_hand_box.scale.x, _hand_k):
		_hand_box.scale = Vector2(_hand_k, _hand_k)
	var orig_x: Vector2 = _hand_box.get_meta("port_orig_x", Vector2.ZERO)
	if not is_equal_approx(_hand_box.offset_left, orig_x.x + _hand_shift):
		_hand_box.offset_left = orig_x.x + _hand_shift
		_hand_box.offset_right = orig_x.y + _hand_shift


# Right (or left) edge of the visible content under `root`, e.g. the energy orb under its zero-size container.
static func _visible_extent(root: Control, right_edge: bool) -> float:
	var edge := -INF if right_edge else INF
	for c in root.find_children("*", "Control", true, false):
		var cc := c as Control
		if cc.is_visible_in_tree() and cc.size.x > 1.0 and cc.size.y > 1.0:
			var r := _global_rect(cc)
			edge = maxf(edge, r.end.x) if right_edge else minf(edge, r.position.x)
	return edge if is_finite(edge) else (_global_rect(root).end.x if right_edge else _global_rect(root).position.x)


# Combat pile buttons slide between a shown and a hidden spot that the game works out once (in _Ready; the exhaust
# pile from the whole canvas): after a resize (an iPhone Duo opening or closing) or with a safe-area inset, the shown
# spot is off and the hidden one is on screen (they peeked out on the map). Recompute both from the container's
# current size and move a pile that rests at an old spot.
const PILE_HIDE := {
	"NDrawPileButton.cs": Vector2(-150, 100),
	"NDiscardPileButton.cs": Vector2(150, 100),
	"NExhaustPileButton.cs": Vector2(150, 0),
}

func _fix_piles() -> void:
	var i := _piles.size() - 1
	while i >= 0:
		var p := _piles[i]
		i -= 1
		if not is_instance_valid(p) or not p.is_inside_tree():
			_piles.remove_at(i + 1)
			continue
		var parent := p.get_parent() as Control
		var show = p.get("_showPosition")
		var hide = p.get("_hidePosition")
		if parent == null or not p.is_node_ready() or not (show is Vector2) or not (hide is Vector2):
			continue
		var kind: String = p.get_script().resource_path.get_file()
		if not p.has_meta("port_pile_gap"):
			# The game's own spot, as distances from the container's corners.
			var off = p.get("_posOffset") if kind == "NExhaustPileButton.cs" else null
			p.set_meta("port_pile_gap", Vector3(show.x, parent.size.x - show.x, parent.size.y - show.y) \
				if not (off is Vector2) else Vector3(0, off.x, off.y))
		var gap: Vector3 = p.get_meta("port_pile_gap")
		var want_show := Vector2(gap.x if kind == "NDrawPileButton.cs" else parent.size.x - gap.y, parent.size.y - gap.z)
		var away: Vector2 = PILE_HIDE[kind]
		away.x += -_inset_left if away.x < 0.0 else _inset_right # all the way off screen
		var want_hide := want_show + away
		if not want_show.is_equal_approx(show) or not want_hide.is_equal_approx(hide):
			# Old spots: the game's (the exhaust pile recomputes its own on a resize) and the ones set here before.
			var prev: Array = [[show, hide]]
			if p.has_meta("port_pile_last"):
				prev.append(p.get_meta("port_pile_last"))
			p.set_meta("port_pile_prev", prev)
			p.set_meta("port_pile_last", [want_show, want_hide])
			p.set("_showPosition", want_show)
			p.set("_hidePosition", want_hide)
		for pair in p.get_meta("port_pile_prev", []):
			# Resting at an old spot (or a tween ending there): move it to the new one.
			if p.position.is_equal_approx(pair[0]) and not pair[0].is_equal_approx(want_show):
				p.position = want_show
			elif p.position.is_equal_approx(pair[1]) and not pair[1].is_equal_approx(want_hide):
				p.position = want_hide


# iOS apps don't quit themselves (swipe the app away instead). The game never shows the button again.
func _hide_quit(menu: Node) -> void:
	var quit := menu.get_node_or_null("MainMenuTextButtons/QuitButton") as Control
	if quit != null:
		quit.visible = false


func _fix_act_banners() -> void:
	var i := _act_banners.size() - 1
	while i >= 0:
		var b := _act_banners[i]
		if not is_instance_valid(b) or not b.is_inside_tree():
			_act_banners.remove_at(i)
		else:
			var number := b.get_node_or_null("ActNumber") as Control
			if number != null:
				# The tween sets position.y in design units (440-450) every frame it runs: when it changed since our
				# last write, move it up by how much higher the banner's centre is on this canvas.
				var written: float = number.get_meta("port_written", INF)
				if not is_equal_approx(number.position.y, written):
					number.position.y += (b.size.y - DESIGN_HEIGHT) / 2.0
					number.set_meta("port_written", number.position.y)
		i -= 1


func _fit_inspect() -> void:
	if _inspect == null or not is_instance_valid(_inspect) or not _inspect.is_node_ready() \
			or not _inspect.is_visible_in_tree():
		return
	var card := _inspect.get_node_or_null("Card") as Control
	var toggle := _inspect.get_node_or_null("Upgrade") as Control
	var tips := _inspect.get_node_or_null("HoverTipRect") as Control
	if card == null or toggle == null or tips == null:
		return
	if not _inspect.has_meta("port_orig"):
		var card_pos = _inspect.get("_cardPosition")
		if not (card_pos is Vector2):
			return
		_inspect.set_meta("port_orig", {
			"card": card_pos,
			"toggle": Vector2(toggle.offset_top, toggle.offset_bottom),
			"tips": Vector4(tips.offset_left, tips.offset_top, tips.offset_right, tips.offset_bottom),
		})
	var orig: Dictionary = _inspect.get_meta("port_orig")
	var h := _inspect.size.y
	var fit: Vector3 = _inspect.get_meta("port_fit", Vector3(-1, 0, 0)) # canvas height, card scale, card y shift
	if not is_equal_approx(fit.x, h):
		var t: Vector2 = orig["toggle"]
		var tip: Vector4 = orig["tips"]
		var s := INSPECT_SCALE
		var dy := 0.0
		if t.y > h / 2.0 - _bottom_margin:
			var half := tip.w / INSPECT_SCALE # card frame half-height at scale 1 (the tooltip area matches the card)
			var avail := h - _bottom_margin - INSPECT_TOP
			s = minf(INSPECT_SCALE, (avail - INSPECT_GAP - (t.y - t.x)) / (2.0 * half + INSPECT_GEM))
			dy = INSPECT_TOP + (INSPECT_GEM + half) * s - h / 2.0
			var k := s / INSPECT_SCALE
			toggle.offset_top = dy + half * s + INSPECT_GAP
			toggle.offset_bottom = toggle.offset_top + (t.y - t.x)
			tips.offset_left = tip.x * k
			tips.offset_right = tip.z * k
			tips.offset_top = dy + tip.y * k
			tips.offset_bottom = dy + tip.w * k
			print("[PORT] card inspect: scale %.2f, raised %.0f (canvas height %.0f)" % [s, -dy, h])
		var base: Vector2 = orig["card"]
		_inspect.set("_cardPosition", base + Vector2(0, dy)) # the game tweens the card back to this
		card.position.y = base.y + dy
		fit = Vector3(h, s, dy)
		_inspect.set_meta("port_fit", fit)
	if card.scale.x > fit.y + 0.001: # Open sets 1.75
		card.scale = Vector2(fit.y, fit.y)


func _apply_insets() -> void:
	var i := _targets.size() - 1
	while i >= 0:
		var c := _targets[i]
		if not is_instance_valid(c) or not c.is_inside_tree():
			_targets.remove_at(i)
		elif INSET_TARGETS[String(c.name)] != "" and String(c.get_parent().name) != INSET_TARGETS[String(c.name)]:
			# Reparented (the star counter moves onto the energy counter): it now follows its new, inset parent.
			_targets.remove_at(i)
		else:
			_inset_control(c)
		i -= 1
	i = _back_buttons.size() - 1
	while i >= 0:
		var b := _back_buttons[i]
		if not is_instance_valid(b) or not b.is_inside_tree():
			_back_buttons.remove_at(i)
		elif b.is_node_ready():
			_shift_back_button(b)
		i -= 1


func _shift_back_button(b: Control) -> void:
	# NBackButton puts itself at (0, ContentScaleSize.Y) - _posOffset, i.e. assumes the canvas is exactly as tall as
	# the content scale size (not so on squarer screens with Expand, e.g. an iPhone Duo, until _enforce catches up
	# after a resize). Recompute that from the real canvas height, plus the safe-area inset.
	var show_pos = b.get("_showPos")
	var pos_offset = b.get("_posOffset")
	if not (show_pos is Vector2) or not (pos_offset is Vector2):
		return
	var want: Vector2 = Vector2(_inset_left, get_viewport().get_visible_rect().size.y) - pos_offset
	if want.is_equal_approx(show_pos):
		return
	b.set("_showPos", want)
	b.set("_hidePos", want + BACK_HIDE_OFFSET)
	b.position += want - show_pos


func _process(delta: float) -> void:
	_enforce()
	_apply_insets()
	if _shots_left != 0:
		_since_shot += delta
		if _since_shot >= SHOT_INTERVAL:
			_since_shot = 0.0
			if _shots_left > 0:
				_shots_left -= 1
			_capture()


func _enforce() -> void:
	var w := get_window()
	# Wide phones: 960 tall, width expands. Squarer screens (an iPhone Duo, iPads): 1680 wide, height expands; the
	# content scale height then follows the canvas, since the game reads it as the canvas height (NBackButton).
	var size := Vector2i(MIN_WIDTH, UI_HEIGHT)
	if w.size.x > 0 and w.size.y > 0 and w.size.x * UI_HEIGHT < w.size.y * MIN_WIDTH:
		size.y = roundi(float(MIN_WIDTH) * w.size.y / w.size.x)
	if w.content_scale_aspect != Window.CONTENT_SCALE_ASPECT_EXPAND or w.content_scale_size != size:
		w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
		w.content_scale_size = size
	var rect := get_viewport().get_visible_rect()
	var safe := DisplayServer.get_display_safe_area()
	if rect != _last_rect or safe != _last_safe:
		_last_rect = rect
		_last_safe = safe
		var k := rect.size.y / w.size.y # raw px -> logical canvas units
		var left := maxi(0, safe.position.x)
		var right := maxi(0, w.size.x - safe.end.x)
		var bottom := maxi(0, w.size.y - safe.end.y)
		_inset_left = left * k
		_inset_right = right * k
		_bottom_margin = maxf(16.0, bottom * k)
		print("[PORT] canvas ", rect.size, " (window ", w.size, ") safe insets px left ", left, " right ", right,
			" top ", safe.position.y, " bottom ", bottom, " = units ", snappedf(_inset_left, 0.1), " / ",
			snappedf(_inset_right, 0.1))


func _capture() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("user://port_shots")
	img.save_jpg("user://port_shots/auto_%02d.jpg" % _shot_index, 0.7)
	_shot_index = (_shot_index + 1) % 20
