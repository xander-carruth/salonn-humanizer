@tool
extends Resource
class_name HumanizerMaterial

const TEXTURE_LAYERS = ['albedo', 'normal', 'ao']
static var material_property_names = get_standard_material_properties()

@export var overlays: Array[HumanizerOverlay] = []
@export_file var base_material_path: String

var is_generating = false

signal done_generating

static func get_standard_material_properties() -> PackedStringArray:
	var prop_names = PackedStringArray()
	#only get properties unique to material, so we can copy those onto existing material instead of gernating a new material and using signals
	
	var base_props = []
	for prop in Material.new().get_property_list():
		base_props.append(prop.name)
	
	for prop in StandardMaterial3D.new().get_property_list():
		var flags = PROPERTY_USAGE_SCRIPT_VARIABLE
		#if prop.name not in base_props and (prop.usage & flags > 0):
		if prop.name not in base_props and prop.usage < 64:
			prop_names.append(prop.name) 
			#print(str(prop.usage) + " " + prop.name)
	if not ProjectSettings.get("rendering/lights_and_shadows/use_physical_light_units"):
		prop_names.remove_at( prop_names.find("emission_intensity"))
	#remove these so it doesnt flash the base texture when it changes (only set texture when its done updating)
	for tex_name in TEXTURE_LAYERS:
		prop_names.remove_at( prop_names.find(tex_name + "_texture"))
	return prop_names

func duplicate(subresources=false):
	if not subresources:
		return super(subresources)
	else:
		var dupe = HumanizerMaterial.new()
		dupe.base_material_path = base_material_path
		for overlay in overlays:
			dupe.overlays.append(overlay.duplicate(true))
		return dupe

func generate_material_3D(material:StandardMaterial3D)->void:
	if not (material is StandardMaterial3D):
		return

	var base_material := StandardMaterial3D.new()
	if FileAccess.file_exists(base_material_path):
		var res = HumanizerResourceService.load_resource(base_material_path)
		# Only treat it as a StandardMaterial3D if it actually is one
		if res is StandardMaterial3D:
			base_material = res
			
		for prop_name in material_property_names:
			material.set(prop_name,base_material.get(prop_name))
		material.resource_local_to_scene = true
		
	if overlays.size() == 0:
		for tex_name in TEXTURE_LAYERS:
			tex_name += "_texture"
			material.set(tex_name , base_material.get(tex_name ))
	elif overlays.size() == 1:
		material.albedo_color = overlays[0].color
		if not overlays[0].albedo_texture_path in ["",null]:
			material.set_texture(BaseMaterial3D.TEXTURE_ALBEDO, HumanizerResourceService.load_resource(overlays[0].albedo_texture_path))
		else:
			material.set_texture(BaseMaterial3D.TEXTURE_ALBEDO,null)
		if overlays[0].normal_texture_path in ["",null]:
			material.normal_enabled = false
			material.set_texture(BaseMaterial3D.TEXTURE_NORMAL,null)
		else:
			material.normal_enabled = true
			material.normal_scale = overlays[0].normal_strength
			material.set_texture(BaseMaterial3D.TEXTURE_NORMAL, HumanizerResourceService.load_resource(overlays[0].normal_texture_path))
		if not overlays[0].ao_texture_path in ["",null]:
			material.set_texture(BaseMaterial3D.TEXTURE_AMBIENT_OCCLUSION, HumanizerResourceService.load_resource(overlays[0].ao_texture_path))
	else:
		is_generating = true
		# awaiting outside the main thread will switch to the main thread if the signal awaited is emitted by the main thread
		HumanizerJobQueue.add_job_main_thread(func():
			var textures = await _update_material()
			material.normal_enabled = textures.normal != null
			material.ao_enabled = textures.ao != null
			material.albedo_texture = textures.albedo
			material.albedo_color = Color.WHITE
			material.normal_texture = textures.normal
			material.normal_scale = 1
			material.ao_texture = textures.ao

			is_generating = false
			done_generating.emit()
		)
	
	# Reflectivity / ambient control (NEW)
	# ----------------------------------------
	var ov_for_surface: HumanizerOverlay = null
	if overlays.size() >= 1:
		ov_for_surface = overlays[0]

	# Only override PBR if the overlay explicitly says so.
	if ov_for_surface != null and ov_for_surface.override_pbr:
		material.metallic = ov_for_surface.metallic
		material.roughness = ov_for_surface.roughness
		material.disable_ambient_light = ov_for_surface.disable_ambient_light
	else:
		# For “no overlay” or override_pbr == false:
		# leave base_material’s lighting alone.
		# (You can still clamp here globally if you want,
		# but for eyes I'd keep the base values.)
		pass

	# Optional: allow some overlays to be effectively unlit
	if ov_for_surface != null and ov_for_surface.unshaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	
func _update_material() -> Dictionary:
	var textures : Dictionary = {}
	if overlays.size() <= 1:
		return textures
		
	for texture in TEXTURE_LAYERS: #albedo, normal, ambient occulsion ect..
		var texture_size = Vector2(2**11,2**11)
		if overlays[0].albedo_texture_path != "":
			texture_size = HumanizerResourceService.load_resource(overlays[0].albedo_texture_path).get_size()
		var image_vp = SubViewport.new()
		
		image_vp.size = texture_size
		image_vp.transparent_bg = true
	
	
		for overlay in overlays:
			if overlay == null:
				continue

			var path = overlay.get(texture + '_texture_path')

			if path == null || path == '':
				if texture == 'albedo':
					print(overlay.albedo_texture_path)
					var im_col_rect = ColorRect.new()
					im_col_rect.color = overlay.color
					image_vp.add_child(im_col_rect)
				continue
			var im_texture = HumanizerResourceService.load_resource(path)
			var im_tex_rect = TextureRect.new()
			im_tex_rect.position = overlay.offset
			im_tex_rect.texture = im_texture
			if texture == 'albedo':
				#blend color with overlay texture and then copy to base image
				im_tex_rect.modulate = overlay.color
			if texture == 'normal':
				if image_vp.get_child_count() == 0:
					var blank_normal = ColorRect.new()
					blank_normal.color = Color(.5,.5,1)
					image_vp.add_child(blank_normal)
					blank_normal.size = texture_size
				im_tex_rect.modulate.a = overlay.normal_strength
			#image_vp.call_deferred("add_child",im_tex_rect)
			image_vp.add_child(im_tex_rect)
		
		if image_vp.get_child_count() == 0:
			textures[texture] = null
		else:
			Engine.get_main_loop().get_root().add_child.call_deferred(image_vp)
			image_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
			if not image_vp.is_inside_tree():
				await Signal(image_vp,"tree_entered")
			await Signal(RenderingServer, "frame_post_draw")
			await RenderingServer.frame_post_draw
			var image = image_vp.get_texture().get_image()
			image.generate_mipmaps()
			textures[texture] = ImageTexture.create_from_image(image)
		image_vp.queue_free()
	return textures


func set_base_textures(overlay: HumanizerOverlay) -> void:
	if overlays.size() == 0:
		# Don't append, we want to call the setter 
		overlays = [overlay]
	overlays[0] = overlay

func add_overlay(overlay: HumanizerOverlay) -> void:
	if _get_index(overlay.resource_name) != -1:
		printerr('Overlay already present?')
		return
	overlays.append(overlay)
	overlay.changed.connect(changed.emit)
	changed.emit()

func set_overlay(idx: int, overlay: HumanizerOverlay) -> void:
	if overlays.size() - 1 >= idx:
		overlays[idx] = overlay
		changed.emit()
	else:
		push_error('Invalid overlay index')

func remove_overlay(ov: HumanizerOverlay) -> void:
	for o in overlays:
		if o == ov:
			overlays.erase(o)
			changed.emit()
			return
	push_warning('Cannot remove overlay ' + ov.resource_name + '. Not found.')
	
func remove_overlay_at(idx: int) -> void:
	if overlays.size() - 1 < idx or idx < 0:
		push_error('Invalid index')
		return
	overlays.remove_at(idx)
	changed.emit()

func remove_overlay_by_name(name: String) -> void:
	var idx := _get_index(name)
	if idx == -1:
		printerr('Overlay not present? ' + name)
		return
	overlays.remove_at(idx)
	changed.emit()
	
func is_shader_base() -> bool:
	if base_material_path in ["", null]:
		return false
	if not FileAccess.file_exists(base_material_path):
		return false
	var res = HumanizerResourceService.load_resource(base_material_path)
	return res is ShaderMaterial
	
func _get_index(name: String) -> int:
	for i in overlays.size():
		if overlays[i].resource_name == name:
			return i
	return -1

func apply_to_material(mat: Material, base_color: Color) -> void:
	if mat is ShaderMaterial:
		generate_shader_material(mat as ShaderMaterial, base_color)
	elif mat is StandardMaterial3D:
		var std := mat as StandardMaterial3D
		generate_material_3D(std)      # existing overlay pipeline
		std.albedo_color = base_color  # final tint

func generate_shader_material(sm: ShaderMaterial, base_color: Color) -> void:
	# 1) Reuse overlay / mhmat pipeline to get a baked base albedo
	var tmp := StandardMaterial3D.new()
	generate_material_3D(tmp)

	if sm.shader == null:
		return
	var shader := sm.shader
	# Base texture
	if tmp.albedo_texture != null and ShaderHelper.shader_has_param(shader, "object_texture"):
		sm.set_shader_parameter("object_texture", tmp.albedo_texture)

	# Base tint (skin/hair/eye color)
	if ShaderHelper.shader_has_param(shader, "albedo"):
		sm.set_shader_parameter("albedo", base_color)

	# Overlay support (first overlay only for now)
	if not ShaderHelper.shader_has_param(shader, "use_overlay"):
		return

	if overlays.is_empty():
		sm.set_shader_parameter("use_overlay", false)
		return

	var ov: HumanizerOverlay = overlays[0]

	sm.set_shader_parameter("use_overlay", true)

	if ShaderHelper.shader_has_param(shader, "overlay_color"):
		sm.set_shader_parameter("overlay_color", ov.color)

	if ShaderHelper.shader_has_param(shader, "overlay_opacity"):
		var opacity := 1.0 # or some field from ov if you add one
		sm.set_shader_parameter("overlay_opacity", opacity)

	if ShaderHelper.shader_has_param(shader, "overlay_texture"):
		var tex: Texture2D = null
		if ov.albedo_texture_path != "" and ov.albedo_texture_path != null:
			tex = HumanizerResourceService.load_resource(ov.albedo_texture_path)
		sm.set_shader_parameter("overlay_texture", tex)
