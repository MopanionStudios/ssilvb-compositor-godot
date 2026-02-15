@tool
extends CompositorEffect
class_name SSGIBlurPass

var rd : RenderingDevice
var pipeline : RID

var shader_src := load("res://ssilvb_blur.glsl")
var shader_spirv : RDShaderSPIRV
var shader : RID

@export var gi_settings : GISettings
var warned : bool = false

var settings_buffer : RID

var sampler_state : RID


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	needs_normal_roughness = true
	rd = RenderingServer.get_rendering_device()

	shader_spirv = shader_src.get_spirv()

	shader = rd.shader_create_from_spirv(shader_spirv)
	pipeline = rd.compute_pipeline_create(shader)
	sampler_state = rd.sampler_create(RDSamplerState.new())



func _notification(what : int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if pipeline.is_valid():
			rd.free_rid(pipeline)
		if shader.is_valid():
			rd.free_rid(shader)
		if settings_buffer.is_valid():
			rd.free_rid(settings_buffer)
		if sampler_state.is_valid():
			rd.free_rid(sampler_state)


func _create_settings_buffer(dir: int):
	
	var hr_int := int(gi_settings.half_res)
	
	var pba := PackedByteArray()
	pba.resize(32)
	pba.encode_float(0, gi_settings.blur_radius)
	pba.encode_float(4, gi_settings.blur_intensity)
	pba.encode_float(8, gi_settings.edge_threshold)
	pba.encode_float(12, gi_settings.ao_strength)
	pba.encode_float(16, gi_settings.gi_intensity)
	pba.encode_u8(20, dir)
	pba.encode_u8(21, hr_int)
	settings_buffer = rd.uniform_buffer_create(pba.size(), pba)


func _create_uniform(binding : int, id : RID, type : RenderingDevice.UniformType) -> RDUniform:
	var uniform = RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	uniform.add_id(id)
	return uniform


func _create_sampler(binding : int, id : RID) -> RDUniform:
	var uniform = RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
	uniform.binding = binding
	uniform.add_id(sampler_state)
	uniform.add_id(id)
	return uniform


func _create_set(set_num : int, uniforms : Array) -> RID:
	var created_set = rd.uniform_set_create(uniforms, shader, set_num)
	return created_set

func compile_compute(sets : Array, push_const : PackedByteArray, _pipeline : RID, size : Vector2i):
	
	if size.x == 0 and size.y == 0:
		return
	
	var x_groups = (size.x - 1) / 8 + 1
	var y_groups = (size.y - 1) / 8 + 1
	var z_groups = 1
	
	var compute_list:= rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, _pipeline)

	for s in sets.size():
		rd.compute_list_bind_uniform_set(compute_list, sets.get(s), s)

	rd.compute_list_set_push_constant(compute_list, push_const, push_const.size())
	rd.compute_list_dispatch(compute_list, x_groups, y_groups, z_groups)
	rd.compute_list_end()

func _render_callback(effect_callback_type, render_data):
	if gi_settings == null:
		if !warned:
			var script_name = get_script().resource_path
			printerr("The GI Settings variable must be set to work. (", script_name, ")")
			warned = true
			return

	# Reset the warning var if gi_settings isn't null anymore
	warned = false

	if rd and effect_callback_type == EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		# Get our render scene buffers object, this gives us access to our render buffers.
		# Note that implementation differs per renderer hence the need for the cast.
		var render_scene_buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers()
		if render_scene_buffers:

			# Get our render size, this is the 3D render resolution!
			var size := render_scene_buffers.get_internal_size()

			# Push constant
			var push_constant := PackedByteArray()
			push_constant.resize(16)
			push_constant.encode_s32(0, size.x)
			push_constant.encode_s32(4, size.y)

			var ssgi_blurred : RID

			if not render_scene_buffers.has_texture("ssgi", "blur_horizontal_result"):
				render_scene_buffers.create_texture("ssgi", "blur_horizontal_result", RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)

			ssgi_blurred = render_scene_buffers.get_texture("ssgi", "blur_horizontal_result")

			# Loop through views just incase its stereo
			var view_count = render_scene_buffers.get_view_count()
			for view in range(view_count):
				# First pass, horizontal blur
				if settings_buffer.is_valid():
					rd.free_rid(settings_buffer)

				_create_settings_buffer(0)
				
				var color_img = render_scene_buffers.get_color_layer(view)
				var output_img = render_scene_buffers.get_texture("ssgi", "result")
				var normal_img = render_scene_buffers.get_texture("forward_clustered", "normal_roughness")
				var ssgi_img = render_scene_buffers.get_texture("ssgi", "result")

				var output_uniform = _create_uniform(0, ssgi_blurred, RenderingDevice.UNIFORM_TYPE_IMAGE)
				var ssgi_uniform = _create_sampler(1, ssgi_img)
				var normal_uniform = _create_sampler(2, normal_img)
				var color_uniform = _create_sampler(3, color_img)

				var settings_uniform = _create_uniform(0, settings_buffer, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER)

				var set_0 = _create_set(0, [output_uniform, ssgi_uniform, normal_uniform, color_uniform])
				var set_1 = _create_set(1, [settings_uniform])

				compile_compute([set_0, set_1], push_constant, pipeline, size)
				rd.free_rid(set_0)
				rd.free_rid(set_1)

				## second pass (vertical blur)
				if settings_buffer.is_valid():
					rd.free_rid(settings_buffer)

				_create_settings_buffer(1)
				
				color_img = render_scene_buffers.get_color_layer(view)
				output_img = render_scene_buffers.get_color_layer(view)
				normal_img = render_scene_buffers.get_texture("forward_clustered", "normal_roughness")
				ssgi_img = render_scene_buffers.get_texture("ssgi", "blur_horizontal_result")

				output_uniform = _create_uniform(0, output_img, RenderingDevice.UNIFORM_TYPE_IMAGE)
				ssgi_uniform = _create_sampler(1, ssgi_img)
				normal_uniform = _create_sampler(2, normal_img)
				color_uniform = _create_sampler(3, color_img)

				settings_uniform = _create_uniform(0, settings_buffer, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER)

				set_0 = _create_set(0, [output_uniform, ssgi_uniform, normal_uniform, color_uniform])
				set_1 = _create_set(1, [settings_uniform])

				compile_compute([set_0, set_1], push_constant, pipeline, size)
				rd.free_rid(set_0)
				rd.free_rid(set_1)
