extends Node
## iOS port: draws the combat background at the resolution of its art instead of the screen's.
##
## Background layers are painted at about 0.74 texels per canvas unit, while an unfolded iPhone Duo shows 1.7 pixels
## per unit, so the GPU shades every background texel several times over. The Underdocks (and its bosses) stack
## around 20 full-screen shader overlays and as many screen-sized glow particles on top, which took 18-22 ms a frame
## there against 6 ms in other acts. Instead, a second viewport renders only the background, at PX_PER_UNIT pixels
## per canvas unit (1680x1182 on the open Duo, about a third of the pixels), and a node in the background's place
## draws that image scaled up to the screen. Creatures, cards, text and the rest of the UI keep the full resolution.
##
## The scene tree isn't changed, so game code and boss scripts keep finding their nodes. The background's nodes move to
## their own visibility layer: the screen's viewport skips that layer, and the background viewport renders only that
## layer of the same canvas. That viewport is transparent, so it holds premultiplied colour (the canvas "mix" blend
## accumulates alpha with ONE / ONE_MINUS_SRC_ALPHA), and the view composites it with premultiplied blending: the
## same as drawing the layers directly. The fades and tints of the background's ancestors are already in that image,
## so the view cancels the ones it inherits from them. display.gd calls before_draw() every frame, after its layout.

const PX_PER_UNIT := 1.0 # background pixels per canvas unit; its art has ~0.74 texels per unit
const MAX_SHARE := 0.9 # used only where the background viewport is at most this share of the screen's width
const LAYER_BIT := 19 # visibility layer 20, unused by the game
const LAYER := 1 << LAYER_BIT
const VIEW_NAME := "PortBackgroundView"

static var px_per_unit := PX_PER_UNIT # tests can lower it to exercise this on a low-resolution window

var _entries := {} # background root -> Entry


class Entry:
	var bg: CanvasItem
	var sub: SubViewport
	var view: View
	var canvas := RID()
	var mask := 0 # the screen viewport's cull mask before this started
	var share := 1.0
	var logged := false


## Draws the background viewport's image over the screen, in the background's place in the draw order.
class View extends Node2D:
	var tex: Texture2D
	var size := Vector2.ZERO

	func _draw() -> void:
		if tex != null:
			draw_texture_rect(tex, Rect2(Vector2.ZERO, size), false)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().node_added.connect(_on_node_added)


func _on_node_added(node: Node) -> void:
	if not (node is CanvasItem) or node.name == VIEW_NAME:
		return
	for bg in _entries:
		if is_instance_valid(bg) and bg.is_ancestor_of(node):
			var e: Entry = _entries[bg]
			if e.sub != null: # before _start, it moves the whole subtree itself
				_move_to_layer(node as CanvasItem, e.mask)
			return
	var parent := node.get_parent()
	if parent == null or parent.name != &"BgContainer" or parent.get_parent() == null \
			or parent.get_parent().name != &"CombatSceneContainer":
		return
	var e := Entry.new()
	e.bg = node as CanvasItem
	_entries[node] = e
	node.tree_exiting.connect(_remove.bind(node), CONNECT_ONE_SHOT)


func before_draw() -> void:
	for bg in _entries.keys():
		var e: Entry = _entries[bg]
		if not is_instance_valid(bg) or not (bg as Node).is_inside_tree():
			_remove(bg)
		elif e.sub == null:
			_start(e)
		else:
			_update(e)


# Pixels per canvas unit and the screen rect (pixels) of the viewport the background is drawn in.
static func _screen(host: Viewport) -> Array:
	var final := host.get_final_transform()
	return [final.get_scale().x, final * host.get_visible_rect()]


func _start(e: Entry) -> void:
	var host := e.bg.get_viewport()
	var s := _screen(host)
	e.share = clampf(px_per_unit / float(s[0]), 0.1, 1.0)
	if e.share > MAX_SHARE:
		_entries.erase(e.bg) # this screen is already close to the art's resolution: nothing to gain
		return
	e.canvas = e.bg.get_canvas()
	e.mask = host.canvas_cull_mask
	host.set_canvas_cull_mask_bit(LAYER_BIT, false)
	# The background and everything under it render only in the background viewport (anything hidden stays hidden);
	# its ancestors render in both, as each viewport only draws items whose parents are all in its layers too.
	_move_to_layer(e.bg, e.mask)
	for n in e.bg.find_children("*", "CanvasItem", true, false):
		_move_to_layer(n as CanvasItem, e.mask)
	var p := e.bg.get_parent()
	while p is CanvasItem:
		(p as CanvasItem).visibility_layer |= LAYER
		p = p.get_parent()
	e.sub = SubViewport.new()
	e.sub.name = "PortBackgroundViewport"
	e.sub.disable_3d = true
	e.sub.transparent_bg = true
	e.sub.use_hdr_2d = host.use_hdr_2d
	e.sub.snap_2d_transforms_to_pixel = host.snap_2d_transforms_to_pixel
	e.sub.snap_2d_vertices_to_pixel = host.snap_2d_vertices_to_pixel
	e.sub.canvas_item_default_texture_filter = host.canvas_item_default_texture_filter
	e.sub.canvas_item_default_texture_repeat = host.canvas_item_default_texture_repeat
	e.sub.canvas_cull_mask = LAYER
	e.sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(e.sub)
	RenderingServer.viewport_attach_canvas(e.sub.get_viewport_rid(), e.canvas)
	e.view = View.new()
	e.view.name = VIEW_NAME
	e.view.tex = e.sub.get_texture()
	e.view.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var premultiplied := CanvasItemMaterial.new()
	premultiplied.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
	e.view.material = premultiplied
	e.view.show_behind_parent = true # drawn before the parent's other children, where the background was
	e.bg.get_parent().add_child(e.view)
	_update(e)


func _update(e: Entry) -> void:
	var host := e.bg.get_viewport()
	var s := _screen(host)
	var screen: Rect2 = s[1]
	var share := clampf(px_per_unit / float(s[0]), 0.1, 1.0) # folding or unfolding the Duo changes it
	var size := Vector2i(ceili(screen.size.x * share), ceili(screen.size.y * share))
	if e.sub.size != size:
		e.sub.size = size
	e.share = share
	# Canvas -> background viewport pixels: the screen's own canvas -> pixel transform, scaled down.
	var to_canvas := e.bg.get_global_transform_with_canvas() * e.bg.get_global_transform().affine_inverse()
	var to_screen := host.get_final_transform() * to_canvas
	var to_sub := Transform2D(0.0, Vector2(share, share), 0.0, -screen.position * share) * to_screen
	RenderingServer.viewport_set_canvas_transform(e.sub.get_viewport_rid(), e.canvas, to_sub)
	# The view's local units are background-viewport pixels, placed over the screen whatever its parents' transforms.
	var parent := e.view.get_parent() as CanvasItem
	var parent_screen := host.get_final_transform() * parent.get_global_transform_with_canvas()
	e.view.transform = parent_screen.affine_inverse() * Transform2D(0.0, Vector2(1.0 / share, 1.0 / share), 0.0, screen.position)
	if e.view.size != Vector2(size):
		e.view.size = Vector2(size)
		e.view.queue_redraw()
	# Ancestors' modulate (a fade, a tint) reaches the view as well as the image: apply it once.
	var m := Color(1, 1, 1, 1)
	var a: Node = parent
	while a is CanvasItem:
		m *= (a as CanvasItem).modulate
		a = a.get_parent()
	e.view.visible = e.bg.visible and m.a > 0.0005
	var undo := Color(1.0 / maxf(m.r, 0.0005), 1.0 / maxf(m.g, 0.0005), 1.0 / maxf(m.b, 0.0005), 1.0 / maxf(m.a, 0.0005))
	if e.view.self_modulate != undo:
		e.view.self_modulate = undo
	if not e.logged:
		e.logged = true
		print("[PORT] background: rendered at %dx%d (%.2f of the screen's %dx%d), scaled up" % [size.x, size.y, share,
			int(screen.size.x), int(screen.size.y)])


static func _move_to_layer(n: CanvasItem, mask: int) -> void:
	if n.name == VIEW_NAME:
		return
	n.visibility_layer = LAYER if n.visibility_layer & mask else 0


func _remove(bg: Variant) -> void:
	var e: Entry = _entries.get(bg)
	_entries.erase(bg)
	if e == null or e.sub == null:
		return
	if is_instance_valid(e.view):
		e.view.queue_free()
	if e.canvas.is_valid():
		RenderingServer.viewport_remove_canvas(e.sub.get_viewport_rid(), e.canvas)
	e.sub.queue_free()
	if _entries.is_empty() and is_instance_valid(e.bg) and e.bg.is_inside_tree():
		e.bg.get_viewport().set_canvas_cull_mask_bit(LAYER_BIT, e.mask & LAYER != 0)
	elif _entries.is_empty():
		get_tree().root.set_canvas_cull_mask_bit(LAYER_BIT, e.mask & LAYER != 0)
