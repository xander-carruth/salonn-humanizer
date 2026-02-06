extends Resource
class_name TargetPreset

@export var slot: StringName
@export var id: StringName
@export var gender: StringName = "general"
@export_file("*.png", "*.webp") var thumbnail_path: String

@export var targets: Dictionary  
@export var overlays: Array[String]
