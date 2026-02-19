@tool
extends CompositorEffect
class_name SSGI

var rd : RenderingDevice
var pipeline : RID

var shader_src := load("res://ssilvb.glsl")
var shader_spirv : RDShaderSPIRV
var shader : RID

@export var gi_settings : GISettings
var saved_half_res : bool

var matrix_buffer : RID
var settings_buffer : RID

var sampler_state : RID


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	needs_normal_roughness = true
	rd = RenderingServer.get_rendering_device()
	
	shader_spirv = shader_src.get_spirv()
	
	shader = rd.shader_create_from_spirv(shader_spirv)
	pipeline = rd.compute_pipeline_create(shader)
	var ss = RDSamplerState.new()
	ss.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	ss.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	
	sampler_state = rd.sampler_create(ss)


func _notification(what : int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if pipeline.is_valid():
			rd.free_rid(pipeline)
		if shader.is_valid():
			rd.free_rid(shader)
		if matrix_buffer.is_valid():
			rd.free_rid(matrix_buffer)
		if settings_buffer.is_valid():
			rd.free_rid(settings_buffer)
		if sampler_state.is_valid():
			rd.free_rid(sampler_state)


func _create_matrix_buffers(render_data : RenderData, view : int) -> RID:
	
	var render_scene_data = render_data.get_render_scene_data()
	
	var mat_buffer : RID
	var proj_matrix = render_scene_data.get_view_projection(view)
	var inv_proj_matrix = proj_matrix.inverse()

	var proj_mat = [
	proj_matrix.x.x, proj_matrix.x.y, proj_matrix.x.z, proj_matrix.x.w,
	proj_matrix.y.x, proj_matrix.y.y, proj_matrix.y.z, proj_matrix.y.w,
	proj_matrix.z.x, proj_matrix.z.y, proj_matrix.z.z, proj_matrix.z.w,
	proj_matrix.w.x, proj_matrix.w.y, proj_matrix.w.z, proj_matrix.w.w,
]

	var inv_proj_mat = [
	inv_proj_matrix.x.x, inv_proj_matrix.x.y, inv_proj_matrix.x.z, inv_proj_matrix.x.w,
	inv_proj_matrix.y.x, inv_proj_matrix.y.y, inv_proj_matrix.y.z, inv_proj_matrix.y.w,
	inv_proj_matrix.z.x, inv_proj_matrix.z.y, inv_proj_matrix.z.z, inv_proj_matrix.z.w,
	inv_proj_matrix.w.x, inv_proj_matrix.w.y, inv_proj_matrix.w.z, inv_proj_matrix.w.w,
]

	var proj_m = PackedFloat32Array(proj_mat).to_byte_array()
	var inv_proj_m = PackedFloat32Array(inv_proj_mat).to_byte_array()

	var pb_array = PackedByteArray()
	pb_array.append_array(proj_m)
	pb_array.append_array(inv_proj_m)

	mat_buffer = rd.uniform_buffer_create(pb_array.size(), pb_array)
	
	return mat_buffer


func _create_settings_buffer():
	
	var hr_int := int(gi_settings.half_res)
	var tp_int := int(gi_settings.use_temporal_accumulation)
	var bf_int := int(gi_settings.use_backface_rejection)
	
	var pba := PackedByteArray()
	pba.resize(32)
	pba.encode_float(0, gi_settings.gi_intensity)
	pba.encode_float(4, gi_settings.radius)
	pba.encode_float(8, gi_settings.hit_thickness)
	pba.encode_s32(12, gi_settings.samples)
	pba.encode_s32(16, gi_settings.slices)
	pba.encode_u8(20, hr_int)
	pba.encode_u8(24, tp_int)
	pba.encode_u8(28, bf_int)
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
		var script_name = get_script().resource_path
		printerr("The GI Settings variable must be set to work. (", script_name, ")")
		enabled = false
		return

	if rd and effect_callback_type == EFFECT_CALLBACK_TYPE_POST_TRANSPARENT:
		# Get our render scene buffers object, this gives us access to our render buffers.
		# Note that implementation differs per renderer hence the need for the cast.
		var render_scene_buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers()
		if render_scene_buffers:
			# Get our render size, this is the 3D render resolution!
			var size := render_scene_buffers.get_internal_size()
			var half_size := Vector2i(size.x / 2, size.y / 2)

			# Create our ssgi image for blurring
			var ssgi_img : RID
			if saved_half_res != gi_settings.half_res:
				render_scene_buffers.clear_context("ssgi")

			if not render_scene_buffers.has_texture("ssgi", "raw_result"):
				saved_half_res = gi_settings.half_res
				if gi_settings.half_res:
					render_scene_buffers.create_texture("ssgi", "raw_result", RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT, RenderingDevice.TEXTURE_SAMPLES_1, half_size, 1, 1, true, false)
				else:
					render_scene_buffers.create_texture("ssgi", "raw_result", RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT, RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT, RenderingDevice.TEXTURE_SAMPLES_1, size, 1, 1, true, false)

			ssgi_img = render_scene_buffers.get_texture("ssgi", "raw_result")

			# Push constant
			var push_constant := PackedByteArray()
			push_constant.resize(32)
			if gi_settings.half_res:
				push_constant.encode_s32(0, half_size.x)
				push_constant.encode_s32(4, half_size.y)
			else:
				push_constant.encode_s32(0, size.x)
				push_constant.encode_s32(4, size.y)
			push_constant.encode_float(8, 0.05)
			push_constant.encode_float(12, 4000.0)
			push_constant.encode_u32(16, Engine.get_frames_drawn())

			if settings_buffer.is_valid():
				rd.free_rid(settings_buffer)
			_create_settings_buffer()

			# Loop through views just incase its stereo
			var view_count = render_scene_buffers.get_view_count()
			for view in range(view_count):
				# Get the RID for our images, we need these for SSGI
				var color_img = render_scene_buffers.get_color_layer(view)
				var depth_img = render_scene_buffers.get_depth_layer(view)
				var normal_img = render_scene_buffers.get_texture("forward_clustered", "normal_roughness")

				var output_uniform = _create_uniform(0, ssgi_img, RenderingDevice.UNIFORM_TYPE_IMAGE)
				var color_uniform = _create_sampler(1, color_img)
				var depth_uniform = _create_sampler(2, depth_img)
				var normal_uniform = _create_sampler(3, normal_img)

				if matrix_buffer.is_valid():
					rd.free_rid(matrix_buffer)
					
				matrix_buffer = _create_matrix_buffers(render_data, view)
				var matrix_uniform = _create_uniform(0, matrix_buffer, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER)

				var settings_uniform = _create_uniform(0, settings_buffer, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER)

				var set_0 = _create_set(0, [output_uniform, color_uniform, depth_uniform, normal_uniform])
				var set_1 = _create_set(1, [matrix_uniform])
				var set_2 = _create_set(2, [settings_uniform])

				if gi_settings.half_res:
					compile_compute([set_0, set_1, set_2], push_constant, pipeline, half_size)
				else:
					compile_compute([set_0, set_1, set_2], push_constant, pipeline, size)
				rd.free_rid(set_0)
				rd.free_rid(set_1)
				rd.free_rid(set_2)
