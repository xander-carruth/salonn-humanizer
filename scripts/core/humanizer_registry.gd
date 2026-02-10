@tool
class_name HumanizerRegistry
extends Node

static var equipment := {}
static var skin_normals := {}
static var overlays := {}
static var rigs := {}
static var target_presets := {}

func _init() -> void:
	load_all()

static func load_all() -> void:
	HumanizerLogger.profile("HumanizerRegistry", func():
		_get_rigs()
		_load_equipment()
		_load_target_presets()
		_get_materials()
	)
	
static func _get_materials():
	for equip_type in equipment.values():
		var mats = HumanizerMaterialService.search_for_materials(equip_type.mhclo_path)
		equip_type.textures = mats.materials
		equip_type.overlays = mats.overlays	
		
static func add_equipment_type(equip:HumanizerEquipmentType):
	#print('Registering equipment ' + equip.resource_name)
	if equipment.has(equip.resource_name):
		equipment.erase(equip.resource_name)
	equipment[equip.resource_name] = equip

static func filter_equipment(filter: Dictionary) -> Array[HumanizerEquipmentType]:
	var filtered: Array[HumanizerEquipmentType] = []

	# --- Normalize filters ---
	var slot_values: Array = []
	var gender_values: Array = []

	# Accept both &'slot' and "slot" as keys
	if filter.has(&"slot") or filter.has("slot"):
		var raw_slot = filter.get(&"slot", filter.get("slot"))
		if raw_slot is Array:
			slot_values = raw_slot.duplicate()
		elif raw_slot != null:
			slot_values = [raw_slot]

	if filter.has(&"gender") or filter.has("gender"):
		var raw_gender = filter.get(&"gender", filter.get("gender"))
		if raw_gender is Array:
			gender_values = raw_gender.duplicate()
		elif raw_gender != null:
			gender_values = [raw_gender]

	var has_slot_filter := slot_values.size() > 0
	var has_gender_filter := gender_values.size() > 0

	for equip in equipment.values():
		var matches := true

		# --- Slot filter (OR within, AND with others) ---
		if has_slot_filter:
			var slot_match := false
			for wanted_slot in slot_values:
				if wanted_slot in equip.slots:
					slot_match = true
					break
			if not slot_match:
				matches = false

		# --- Gender filter (OR within, AND with others) ---
		if matches and has_gender_filter:
			var gender_match := false
			for wanted_gender in gender_values:
				if equip.gender == wanted_gender:
					gender_match = true
					break
			if not gender_match:
				matches = false

		if matches:
			filtered.append(equip)

	return filtered


#static func filter_target_presets(filter: Dictionary) -> Array[TargetPreset]:
	#var filtered: Array[TargetPreset]
	#for preset in target_presets.values():
		#for key in filter:
			#if key == &'slot':
				#if filter[key] == preset.slot:
					#filtered.append(preset)
	#return filtered

static func filter_target_presets(filter: Dictionary) -> Array[TargetPreset]:
	var filtered: Array[TargetPreset] = []

	# --- Normalize filters ---
	var slot_values: Array = []
	var gender_values: Array = []

	# Accept both &'slot' and "slot" as keys
	if filter.has(&"slot") or filter.has("slot"):
		var raw_slot = filter.get(&"slot", filter.get("slot"))
		if raw_slot is Array:
			slot_values = raw_slot.duplicate()
		elif raw_slot != null:
			slot_values = [raw_slot]

	if filter.has(&"gender") or filter.has("gender"):
		var raw_gender = filter.get(&"gender", filter.get("gender"))
		if raw_gender is Array:
			gender_values = raw_gender.duplicate()
		elif raw_gender != null:
			gender_values = [raw_gender]

	var has_slot_filter := slot_values.size() > 0
	var has_gender_filter := gender_values.size() > 0

	for preset in target_presets.values():
		var matches := true

		# --- Slot filter (OR within, AND with others) ---
		if has_slot_filter:
			var slot_match := false
			for wanted_slot in slot_values:
				if wanted_slot == preset.slot:
					slot_match = true
					break
			if not slot_match:
				matches = false

		# --- Gender filter (OR within, AND with others) ---
		if matches and has_gender_filter:
			var gender_match := false
			for wanted_gender in gender_values:
				if preset.gender == wanted_gender:
					gender_match = true
					break
			if not gender_match:
				matches = false

		if matches:
			filtered.append(preset)

	return filtered

static func _get_rigs() -> void:
	#  Create and/or cache rig resources
	for folder in HumanizerGlobalConfig.config.asset_import_paths:
		var rig_path = folder.path_join('rigs')
		for dir in OSPath.get_dirs(rig_path):
			var name = dir.get_file()
			rigs[name] = HumanizerRig.new()
			rigs[name].resource_name = name
			for file in OSPath.get_files(dir):
				if file.get_extension() == 'json' and file.get_file().begins_with('rig'):
					rigs[name].mh_json_path = file
				elif file.get_extension() == 'json' and file.get_file().begins_with('weights'):
					rigs[name].mh_weights_path = file
				elif file.get_file() == 'skeleton_config.json':
					rigs[name].config_json_path = file
				elif file.get_file() == 'bone_weights.json':
					rigs[name].bone_weights_json_path = file
				elif (file.get_extension() == 'tscn' or file.ends_with(".tscn.remap")) and file.get_file().begins_with('general'):
					rigs[name].skeleton_retargeted_path = file.trim_suffix('.remap')
				elif file.get_extension() == 'tscn' or file.ends_with(".tscn.remap"):
					rigs[name].skeleton_path  = file.trim_suffix('.remap')
				elif file.get_extension() == 'res':
					rigs[name].rigged_mesh_path = file

static func _load_equipment() -> void:
	equipment={}
	for path in HumanizerGlobalConfig.config.asset_import_paths:
		for dir in OSPath.get_dirs(path.path_join('equipment')):
			_scan_dir_for_equipment(dir)

static func _scan_dir_for_equipment(path: String) -> void:
	var contents := OSPath.get_contents(path)

	# Recurse into subdirs
	for folder in contents.dirs:
		_scan_dir_for_equipment(folder)

	# Files
	for file in contents.files:
		var ext = file.get_extension().to_lower()

		# We only care about .res here; ignore .tres completely
		if ext != "res":
			continue

		# Filter out non-equipment .res files, e.g. *.material.res, *.mhclo.res, etc.
		var base = file.get_file()
		if base.ends_with(".material.res") or base.ends_with(".mhclo.res"):
			continue

		var equip = HumanizerResourceService.load_resource(file)
		if equip is HumanizerEquipmentType:
			add_equipment_type(equip)
		else: 
			printerr("unexpected resource type " + file)

static func _load_target_presets() -> void:
	target_presets={}
	for path in HumanizerGlobalConfig.config.asset_import_paths:
		for dir in OSPath.get_dirs(path.path_join('target_presets')):
			_scan_dir_for_presets(dir)

static func _scan_dir_for_presets(path: String) -> void:
	var contents := OSPath.get_contents(path)

	# Recurse into subdirs
	for folder in contents.dirs:
		_scan_dir_for_presets(folder)

	# Files
	for file in contents.files:
		var ext = file.get_extension().to_lower()

		# We only care about .tres here
		if ext != "tres":
			continue

		# Filter out non-equipment .res files, e.g. *.material.res, *.mhclo.res, etc.
		var base = file.get_file()

		var preset = HumanizerResourceService.load_resource(file)
		if preset is TargetPreset:
			add_target_preset(preset)
		else: 
			printerr("unexpected resource type " + file)
			
static func add_target_preset(target_preset: TargetPreset):
	#print('Registering equipment ' + equip.resource_name)
	if target_presets.has(target_preset.id):
		target_presets.erase(target_preset.id)
	target_presets[target_preset.id] = target_preset
