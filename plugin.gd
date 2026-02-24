@tool
extends EditorPlugin

# The new node type to be added
const humanizer_node = preload('res://addons/humanizer/scripts/utils/humanizer_editor_tool.gd')
# Its icon in the scene tree
const node_icon = preload('res://addons/humanizer/icon.png')
# Editor inspectors 
var humanizer_inspector = HumanizerEditorInspectorPlugin.new()
var asset_import_inspector = AssetImporterInspectorPlugin.new()
var human_randomizer_inspector = HumanRandomizerInspectorPlugin.new()
var humanizer_material_inspector = HumanizerMeshInstanceInspectorPlugin.new()

# For mapping tool menu signals
const menu_ids := {
	'generate_base_mesh': 1,
	'read_shapekeys': 2,
	'rig_config': 4,
	'image_import_settings': 5,
	'process_raw_data': 10,
	'reload_registry': 20,
	'purge_generated_assets': 29,
	'asset_importer': 30,
	'import_selected_folder': 31,
	'delete_equipment': 32,
	'test': 999,
}

# Thread for background tasks
var thread := Thread.new()


func _enter_tree():
	# Load global config singleton
	add_autoload_singleton('HumanizerGlobal', "res://addons/humanizer/scenes/humanizer_global.tscn")
	# Add editor inspector plugins
	add_inspector_plugin(humanizer_inspector)
	add_inspector_plugin(asset_import_inspector)
	add_inspector_plugin(human_randomizer_inspector)
	add_inspector_plugin(humanizer_material_inspector)
	# Add custom humanizer node
	add_custom_type('Humanizer', 'Node3D', humanizer_node, node_icon)
	# Add a submenu to the Project/Tools menu
	_add_tool_submenu()

func _exit_tree():
	remove_custom_type('Humanizer')
	remove_tool_menu_item('Humanizer')
	remove_inspector_plugin(humanizer_inspector)
	remove_inspector_plugin(asset_import_inspector)
	remove_inspector_plugin(human_randomizer_inspector)
	remove_inspector_plugin(humanizer_material_inspector)
	remove_autoload_singleton('HumanizerGlobal')
	if thread.is_started():
		thread.wait_to_finish()
		
func _add_tool_submenu() -> void:
	# Should we cache this to clean up signals in _exit_tree?
	var popup_menu = PopupMenu.new()
	var preprocessing_popup = PopupMenu.new()
	var import_assets_popup = PopupMenu.new()
	
	preprocessing_popup.name = 'preprocessing_popup'
	preprocessing_popup.add_item('Generate Base Meshes', menu_ids.generate_base_mesh)
	preprocessing_popup.add_item('Read ShapeKey files', menu_ids.read_shapekeys)
	preprocessing_popup.add_item('Set Up Skeleton Configs', menu_ids.rig_config)
	preprocessing_popup.add_item('Import Images as Uncompressed (Optional)', menu_ids.image_import_settings)
	
	popup_menu.add_child(preprocessing_popup)
	popup_menu.add_submenu_item('Preprocessing Tasks', 'preprocessing_popup')
	popup_menu.add_item('Run All Preprocessing', menu_ids.process_raw_data)
	popup_menu.add_item('Purge Generated Asset Resources', menu_ids.purge_generated_assets)
	popup_menu.add_item('Import All Assets', menu_ids.asset_importer)
	popup_menu.add_item('Import Selected Folder', menu_ids.import_selected_folder)
	popup_menu.add_item('Unimport Selected Folder(s)', menu_ids.delete_equipment)
	
	popup_menu.add_item('Reload Registry', menu_ids.reload_registry)
	popup_menu.add_item('Run Test Function', menu_ids.test)
	
	add_tool_submenu_item('Humanizer', popup_menu)
	popup_menu.id_pressed.connect(_handle_menu_event)
	preprocessing_popup.id_pressed.connect(_handle_menu_event)

func _handle_menu_event(id) -> void:
	if thread.is_alive():
		printerr('Thread busy...  Try again after current task completes')
		return
	if thread.is_started():
		thread.wait_to_finish()
	if id == menu_ids.generate_base_mesh:
		thread.start(_generate_base_meshes)
	elif id == menu_ids.read_shapekeys:
		thread.start(_read_shapekeys)
	elif id == menu_ids.rig_config:
		thread.start(_rig_config)
	elif id == menu_ids.image_import_settings:
		thread.start(_image_import_settings)
	elif id == menu_ids.process_raw_data:
		_process_raw_data()
	elif id == menu_ids.asset_importer:
		thread.start(_import_assets)
	elif id == menu_ids.import_selected_folder:
		thread.start(_import_selected_folder)
	elif id == menu_ids.delete_equipment:
		thread.start(_delete_selected_equipment)          
	elif id == menu_ids.purge_generated_assets:
		thread.start(_purge_assets)
	elif id == menu_ids.reload_registry:
		HumanizerRegistry.load_all()
	elif id == menu_ids.test:
		thread.start(_test)

#region Thread Tasks
func _process_raw_data() -> void:
	print_debug('Running all preprocessing')
	for task in [
		_generate_base_meshes,
		_read_shapekeys,
		_rig_config,
		_image_import_settings
	]:
		thread.start(task)
		while thread.is_alive():
			await get_tree().create_timer(1).timeout
		thread.wait_to_finish()
	
func _generate_base_meshes() -> void:
	ReadBaseMesh.new().run()
	
func _read_shapekeys() -> void:
	ShapeKeyReader.new().run()
	
func _rig_config() -> void:
	HumanizerSkeletonConfig.new().run()

func _image_import_settings() -> void:
	HumanizerImageImportSettings.new().run()

func _import_assets() -> void:
	HumanizerEquipmentImportService.import_all()
	
func _purge_assets() -> void:
	HumanizerAssetImporter.new().run(true)
	
func _import_selected_folder() -> void:
	var fs_dock := get_editor_interface().get_file_system_dock()
	var paths: PackedStringArray = get_editor_interface().get_selected_paths()

	if paths.is_empty():
		# fallback: use current path if no explicit selection
		var current = fs_dock.get_current_path()
		if current != "":
			paths.append(current)

	if paths.is_empty():
		printerr("Humanizer: No path selected in FileSystem dock.")
		return

	# Prefer a directory; if you selected a file, use its containing folder
	var target_path := paths[0]
	if not DirAccess.dir_exists_absolute(target_path):
		target_path = target_path.get_base_dir()

	if not DirAccess.dir_exists_absolute(target_path):
		printerr("Humanizer: Selected path is not a valid directory: ", target_path)
		return

	print("Humanizer: Importing folder: ", target_path)

	# 1) Make sure .import_settings.json exist for mhclo in this subtree
	HumanizerEquipmentImportService.scan_for_missing_import_settings(target_path, false)

	# 2) Generate materials just for this folder
	HumanizerMaterialService.import_materials(target_path)

	# 3) Import all equipment under this folder (your existing logic)
	HumanizerEquipmentImportService.import_folder(target_path)

	# 4) Refresh registry once
	HumanizerRegistry.load_all()
	print("Humanizer: Finished importing folder ", target_path)

func _delete_selected_equipment() -> void:
	var paths: PackedStringArray = get_editor_interface().get_selected_paths()
	if paths.is_empty():
		push_error("Select an .mhclo or an equipment folder in the FileSystem dock first.")
		return

	for p in paths:
		if p.ends_with(".mhclo"):
			HumanizerEquipmentImportService.delete_equipment_for_mhclo(p)
		elif DirAccess.dir_exists_absolute(p):
			HumanizerEquipmentImportService.delete_equipment_folder(p)

	HumanizerResourceService.clear_cache()
	HumanizerRegistry.load_all()
	print("Humanizer: deleted selected equipment and reloaded registry.")

	
func _test() -> void:
	print(typeof('test'))
#endregion
