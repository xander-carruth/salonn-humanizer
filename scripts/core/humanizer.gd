@tool
extends Resource
class_name Humanizer

var human_config:HumanConfig
var helper_vertex:PackedVector3Array = []
var mesh_arrays : Dictionary = {}
var materials: Dictionary = {}
var rig: HumanizerRig 
var skeleton_data : Dictionary = {} #bone names with parent, position and rotation data

signal done_generating_materials

# if eyes are blank, wait for done_generating_materials in calling class 
func load_config_async(_human_config:HumanConfig):
	var timer
	materials = {}
	mesh_arrays = {}
	skeleton_data = {}
	rig = null
	human_config = _human_config

	helper_vertex = HumanizerTargetService.init_helper_vertex(human_config.targets)

	HumanizerLogger.profile("load equipment", func():
		for equip in human_config.equipment.values():
			mesh_arrays[equip.type] = HumanizerEquipmentService.load_mesh_arrays(equip.get_type())
			init_equipment_material(equip)
	)

	fit_all_meshes()
	set_rig(human_config.rig) #this adds the rigged bones and updates all the bone weights
	if not check_materials_done_generating():
		await done_generating_materials
	
# there are race conditions in this function (i think)
func get_CharacterBody3D(baked:bool):
	var human = CharacterBody3D.new()

	HumanizerLogger.profile("humanizer.get_CharacterBody3D", func():
		hide_clothes_vertices()
		
		human.set_script(HumanizerResourceService.load_resource("res://addons/humanizer/scripts/utils/human_controller.gd"))
		var skeleton = get_skeleton()
		human.add_child(skeleton)
		skeleton.set_unique_name_in_owner(true)
		var body_mesh = MeshInstance3D.new()
		body_mesh.name = "Avatar"
		if baked:
			body_mesh.mesh = standard_bake_meshes()
		else:
			HumanizerLogger.profile("humanizer.get_CharacterBody3D.get_combined_meshes", func():
				body_mesh.mesh = get_combined_meshes()
			)
		human.add_child(body_mesh)
		body_mesh.skeleton = NodePath('../' + skeleton.name)
		body_mesh.skin = skeleton.create_skin_from_rest_transforms()

		var anim_player = get_animation_tree()
		if anim_player != null:
			human.add_child(anim_player)
			anim_player.active=true
		skeleton.owner = human
		anim_player.owner = human
		if human_config.has_component("main_collider"):
			human.add_child(get_main_collider())
		if human_config.has_component("ragdoll"):
			add_ragdoll_colliders(skeleton)
	)

	return human

func get_combined_meshes() -> ArrayMesh:
	var new_mesh = ArrayMesh.new()
	for equip_name in mesh_arrays:
		var new_arrays = get_mesh_arrays(equip_name)
		if not new_arrays.is_empty():
			new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,new_arrays)
			var surface_id = new_mesh.get_surface_count()-1
			new_mesh.surface_set_material(surface_id,materials[equip_name])
			new_mesh.surface_set_name(surface_id,equip_name)
	return new_mesh
	
func get_animation_tree():
	if human_config.rig == 'default-RETARGETED':
		return HumanizerResourceService.load_resource("res://addons/humanizer/data/animations/face_animation_tree.tscn").instantiate()
	elif human_config.rig.ends_with('RETARGETED'):
		return HumanizerResourceService.load_resource("res://addons/humanizer/data/animations/animation_tree.tscn").instantiate()
	else:  # No example animator for specific rigs that aren't retargeted
		return

func standard_bake_meshes():
	var new_mesh = ArrayMesh.new()
	var opaque = get_group_bake_arrays("opaque")
	if not opaque.is_empty():
		combine_surfaces_to_mesh(opaque,new_mesh)		
	var transparent = get_group_bake_arrays("transparent")
	if not transparent.is_empty():
		combine_surfaces_to_mesh(transparent,new_mesh)	
	HumanizerJobQueue.add_job(HumanizerMeshService.compress_material.bind(new_mesh))
	return new_mesh

func combine_surfaces_to_mesh(surface_names:PackedStringArray,new_mesh:=ArrayMesh.new(),atlas_resolution:int=HumanizerGlobalConfig.config.atlas_resolution):
	var bake_arrays = []
	var bake_mats = []
	for s_name in surface_names:
		var new_array = mesh_arrays[s_name].duplicate()
		new_array[Mesh.ARRAY_CUSTOM0] = null
		bake_arrays.append(new_array)
		bake_mats.append(materials[s_name])
	var surface = HumanizerMeshService.combine_surfaces(bake_arrays,bake_mats,atlas_resolution)
	new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,surface.arrays)
	new_mesh.surface_set_material(new_mesh.get_surface_count()-1,surface.material)
	return new_mesh
	
func get_group_bake_arrays(group_name:String): #transparent, opaque or all
	var surface_names = PackedStringArray()
	for s_name in mesh_arrays:
		if group_name.to_lower() == "all":
			surface_names.append(s_name)
		elif materials[s_name].transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
			if group_name.to_lower() == "opaque":
				surface_names.append(s_name)
		else:
			if group_name.to_lower() == "transparent":
				surface_names.append(s_name)
	return surface_names

func set_skin_color(color:Color):
	human_config.skin_color = color
	var body = human_config.get_equipment_in_slot("Body")
	if body == null:
		return

	var mat := materials.get(body.type)
	if mat == null:
		return

	body.material_config.apply_to_material(mat, color)
	
func set_eye_color(color:Color):
	human_config.eye_color = color
	var slots = ["LeftEye", "RightEye", "Eyes"]

	for equip in human_config.get_equipment_in_slots(slots):
		if equip.material_config.overlays.size() > 1:
			equip.material_config.overlays[1].color = color
		
func set_hair_color(color:Color):
	human_config.hair_color = color
	var hair_equip = human_config.get_equipment_in_slot("Hair")
	if hair_equip != null:
		var mat := materials.get(hair_equip.type)
		if mat != null:
			hair_equip.material_config.apply_to_material(mat, color)

	set_eyebrow_color(human_config.eyebrow_color)

func set_eyebrow_color(color:Color):
	human_config.eyebrow_color = color
	var slots = ["LeftEyebrow", "RightEyebrow", "Eyebrows"]

	for eyebrow_equip in human_config.get_equipment_in_slots(slots):
		var mat := materials.get(eyebrow_equip.type)
		if mat == null:
			continue

		_set_material_color(mat, color, "albedo")

func _set_material_color(mat: Material, color: Color, uniform_name: StringName = "albedo") -> void:
	if mat == null:
		return

	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		if sm.shader != null and ShaderHelper.shader_has_param(sm.shader, uniform_name):
			sm.set_shader_parameter(uniform_name, color)
	elif mat is StandardMaterial3D:
		var std := mat as StandardMaterial3D
		std.albedo_color = color

func init_equipment_material(equip:HumanizerEquipment): #called from thread
	var equip_type = equip.get_type()
	var mat_config: HumanizerMaterial = equip.material_config

	var material: Material

	# --- NEW: shader-aware branch ---
	if mat_config.is_shader_base():
		# Base is a ShaderMaterial .tres – duplicate it and use as-is
		var base_res = HumanizerResourceService.load_resource(mat_config.base_material_path)
		var shader_mat := (base_res as ShaderMaterial).duplicate()
		shader_mat.resource_local_to_scene = true

		# Apply overlays + base color (use white as default tint here;
		# runtime color setters will re-apply with the proper color).
		var base_color := _get_base_color_for_equip(equip)
		mat_config.apply_to_material(shader_mat, base_color)

		material = shader_mat
	else:
		# Old behavior: standard PBR pipeline driven by overlays
		var std_mat := StandardMaterial3D.new()
		std_mat.resource_local_to_scene = true
		material = std_mat

		if not mat_config.done_generating.is_connected(check_materials_done_generating):
			mat_config.done_generating.connect(check_materials_done_generating)
		mat_config.generate_material_3D(std_mat)

	materials[equip.type] = material

func check_materials_done_generating():
	for equip in human_config.equipment.values():
		if equip.material_config.is_generating:
			return false
	done_generating_materials.emit()
	return true

func set_equipment_material(equip:HumanizerEquipment, material_name: String)-> void:
	human_config.set_equipment_material(equip,material_name)
	init_equipment_material(equip)

#func update_material(equip_type: String) -> void:
	#var equip = human_config.equipment[equip_type]
	#var mat_config: HumanizerMaterial = equip.material_config
	#var material = materials[equip_type]
#
	## If this is a shader-based material, we don’t try to rebuild it
	#if mat_config.is_shader_base():
		#return
#
	## Standard case – re-generate properties/textures on the existing StandardMaterial3D
	#mat_config.generate_material_3D(material as StandardMaterial3D)

func update_material(equip_type: String) -> void:
	var equip: HumanizerEquipment = human_config.equipment.get(equip_type)
	if equip == null:
		return

	var mat: Material = materials.get(equip.type)
	if mat == null:
		return

	var mat_config: HumanizerMaterial = equip.material_config
	if mat_config == null:
		return

	if mat is StandardMaterial3D:
		# Original behavior: rebuild the StandardMaterial3D from overlays/base mat
		mat_config.generate_material_3D(mat as StandardMaterial3D)
	else:
		# NEW: shader-based path (toon, etc.)
		var base_color := _get_base_color_for_equip(equip)
		mat_config.apply_to_material(mat, base_color)

func _get_base_color_for_equip(equip: HumanizerEquipment) -> Color:
	var t = equip.get_type()

	if t.in_slot(["Body"]):
		return human_config.skin_color
	elif t.in_slot(["Hair"]):
		return human_config.hair_color
	elif t.in_slot(["LeftEye", "RightEye", "Eyes"]):
		return human_config.eye_color
	elif t.in_slot(["LeftEyebrow", "RightEyebrow", "Eyebrows"]):
		return human_config.eyebrow_color

	return Color.WHITE

func get_mesh(mesh_name:String):
	var mesh = ArrayMesh.new()
	var new_arrays = get_mesh_arrays(mesh_name)
	if not new_arrays.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,new_arrays)
		mesh.surface_set_material(0,materials[mesh_name])
	##TODO mesh transform	
	return mesh

func get_mesh_arrays(mesh_name:String) -> Array: # generate normals/tangents, without the cutom0
	#print("getting mesh arrays")
	var new_arrays = mesh_arrays[mesh_name].duplicate()
	new_arrays[Mesh.ARRAY_CUSTOM0] = null
	if new_arrays[Mesh.ARRAY_INDEX].is_empty():
		return []
	new_arrays = HumanizerMeshService.generate_normals_and_tangents(new_arrays)
	return new_arrays
	
func add_equipment(equip:HumanizerEquipment):
	human_config.add_equipment(equip)
	var equip_type = equip.get_type()
	mesh_arrays[equip_type.resource_name] = HumanizerEquipmentService.load_mesh_arrays(equip_type)
	fit_equipment_mesh(equip_type.resource_name)
	if equip_type.rigged:
		HumanizerRigService.skeleton_add_rigged_equipment(equip,mesh_arrays[equip_type.resource_name], skeleton_data)
	update_equipment_weights(equip_type.resource_name)
	init_equipment_material(equip)

func remove_equipment(equip:HumanizerEquipment):
	human_config.remove_equipment(equip)
	var equip_type = equip.get_type()
	mesh_arrays.erase(equip_type.resource_name)
	if equip_type.rigged:
		HumanizerRigService.skeleton_remove_rigged_equipment(equip, skeleton_data)
	materials.erase(equip_type.resource_name)
	
func get_body_mesh():
	return get_mesh("Body")

func hide_clothes_vertices():
	HumanizerEquipmentService.hide_vertices(human_config.equipment,mesh_arrays)

func show_clothes_vertices():
	HumanizerEquipmentService.show_vertices(human_config.equipment,mesh_arrays)
			
func set_targets(target_data:Dictionary):
	HumanizerTargetService.set_targets(target_data,human_config.targets,helper_vertex)
	fit_all_meshes()
	HumanizerRigService.adjust_bone_positions(skeleton_data,rig,helper_vertex,human_config.equipment,mesh_arrays)

func fit_all_meshes():
	for equip_name in human_config.equipment:
		fit_equipment_mesh(equip_name)

func fit_equipment_mesh(equip_name:String):
	var equip:HumanizerEquipment = human_config.equipment[equip_name]
	var mhclo = HumanizerResourceService.load_resource(equip.get_type().mhclo_path)
	mesh_arrays[equip_name] = HumanizerEquipmentService.fit_mesh_arrays(mesh_arrays[equip_name],helper_vertex,mhclo)

func set_rig(rig_name:String):
	human_config.rig = rig_name
	var retargeted: bool = rig_name.ends_with('-RETARGETED')
	rig = HumanizerRigService.get_rig(rig_name)
	skeleton_data = HumanizerRigService.init_skeleton_data(rig,retargeted)
	for equip in human_config.equipment.values():
		if equip.get_type().rigged:
			HumanizerRigService.skeleton_add_rigged_equipment(equip,mesh_arrays[equip.type],skeleton_data)
	HumanizerRigService.adjust_bone_positions(skeleton_data,rig,helper_vertex,human_config.equipment,mesh_arrays)
	update_bone_weights()
	if &'root_bone' in human_config.components:
		enable_root_bone_component()

func get_skeleton()->Skeleton3D:
	#print(skeleton_data)
	var skeleton = HumanizerRigService.get_skeleton_3D(skeleton_data)
	skeleton.motion_scale = HumanizerRigService.get_motion_scale(human_config.rig,helper_vertex)
	return skeleton

func rebuild_skeleton(skeleton:Skeleton3D):
	HumanizerRigService.rebuild_skeleton_3D(skeleton,skeleton_data)

func adjust_skeleton(skeleton:Skeleton3D):
	HumanizerRigService.adjust_skeleton_3D(skeleton,skeleton_data)
	skeleton.motion_scale = HumanizerRigService.get_motion_scale(human_config.rig,helper_vertex)

func update_bone_weights():
	for equip_name in human_config.equipment:
		update_equipment_weights(equip_name)
		
func update_equipment_weights(equip_name:String):
	var equip_type:HumanizerEquipmentType = human_config.equipment[equip_name].get_type()
	var mhclo = HumanizerResourceService.load_resource(equip_type.mhclo_path)
	if equip_type.rigged:
		var bones = mhclo.rigged_bones[rig.resource_name].duplicate() #could potentially have multiple of the same mhclo open, dont want to change other arrays (due to godot resource sharing)
		for bone_array_id in bones.size():
			var bone_id = bones[bone_array_id]
			if bone_id < 0:
				bone_id = skeleton_data.keys().find( mhclo.rigged_config[(bone_id +1) *-1].name) #offset by one because -0 = 0
				bones[bone_array_id] = bone_id
		mesh_arrays[equip_name][Mesh.ARRAY_BONES] = bones
		mesh_arrays[equip_name][Mesh.ARRAY_WEIGHTS] = mhclo.rigged_weights[rig.resource_name].duplicate()
	else:
		mesh_arrays[equip_name][Mesh.ARRAY_BONES] = mhclo.bones[rig.resource_name].duplicate()
		mesh_arrays[equip_name][Mesh.ARRAY_WEIGHTS] = mhclo.weights[rig.resource_name].duplicate()
	
func enable_root_bone_component():
	human_config.enable_component(&'root_bone')
	if "Root" not in skeleton_data:
		skeleton_data.Root = {local_xform=Transform3D(),global_pos=Vector3(0,0,0)}
		skeleton_data[skeleton_data.keys()[0]].parent = "Root"

func disable_root_bone_component():
	human_config.disable_component(&'root_bone')
	if "Root" in skeleton_data and "game_engine" not in human_config.rig:
		skeleton_data.erase("Root")
		skeleton_data[skeleton_data.keys()[0]].erase("parent")
		
func get_main_collider():
	return HumanizerColliderService.get_main_collider(helper_vertex)

func adjust_main_collider(main_collider:CollisionShape3D):
	HumanizerColliderService.adjust_main_collider(helper_vertex,main_collider)

func add_ragdoll_colliders(skeleton:Skeleton3D,ragdoll_layers =HumanizerGlobalConfig.config.default_physical_bone_layers,ragdoll_mask=HumanizerGlobalConfig.config.default_physical_bone_mask):
	skeleton.reset_bone_poses()
	HumanizerPhysicalSkeleton.new(skeleton, helper_vertex, ragdoll_layers, ragdoll_mask).run()
	skeleton.reset_bone_poses()
	
func get_foot_offset()->float:
	return HumanizerBodyService.get_foot_offset(helper_vertex)
	
func get_hips_height()->float:
	return HumanizerBodyService.get_hips_height(helper_vertex)

func get_head_height()->float:
	return HumanizerBodyService.get_head_height(helper_vertex)
	
func get_max_width()->float:
	return HumanizerBodyService.get_max_width(helper_vertex)
