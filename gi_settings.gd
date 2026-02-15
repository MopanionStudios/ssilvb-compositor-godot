extends Resource
class_name GISettings

@export_category("Global Illumination Settings")
@export var radius : float = 0.5
@export var gi_intensity : float = 0.5
@export var samples : int = 4
@export var slices : int = 4

@export_category("Ambient Occlusion Settings")
@export_range(0.0, 1.0, 0.01) var ao_strength : float = 0.5
@export_range(0.0, 1.0, 0.01) var hit_thickness : float = 0.5

@export_category("Blur Settings")
@export var blur_radius : float = 1.5
@export var blur_intensity : float = 1.0
@export_range(0.0, 20.0, 0.01) var edge_threshold : float = 4.0

@export_category("Optimization")
@export var half_res : bool = false
@export var use_backface_rejection : bool = false
@export var use_temporal_accumulation : bool = false
