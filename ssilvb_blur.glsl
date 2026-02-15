#[compute]
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform restrict writeonly image2D output_image;


// Buffers
layout(set = 0, binding = 1) uniform sampler2D indirect_lighting_buffer;
layout(set = 0, binding = 2) uniform sampler2D normal_buffer;
layout(set = 0, binding = 3) uniform sampler2D color_buffer;

layout(set = 1, binding = 0) uniform SceneParams {
    float blur_radius;
    float blur_intensity;
    float edge_threshold;
    float ao_strength;
    float gi_strength;
    int blur_dir;
    bool half_res;
} params;


// Push constant
layout(push_constant, std430) uniform Params {
    ivec2 screen_size;
} push_params;


// Helper functions
vec4 normal_roughness_compatibility(vec4 p_normal_roughness) {
	float roughness = p_normal_roughness.w;
	if (roughness > 0.5) {
		roughness = 1.0 - roughness;
	}
	roughness /= (127.0 / 255.0);
	return vec4(normalize(p_normal_roughness.xyz * 2.0 - 1.0) * 0.5 + 0.5, roughness);
}

vec2 get_blur_coord(vec2 p, int i) {
    int multiplier = (i - 4);
    float blur_step = float(multiplier) * params.blur_intensity;

    vec2 p_size = 1.0 / vec2(push_params.screen_size);

    vec2 offset = params.blur_dir == 0 ? vec2(blur_step * p_size.x, 0.0) : vec2(0.0, blur_step * p_size.y);

    vec2 blur_coord = p + offset;

    return blur_coord;
}


vec4 bilateral_blur(ivec2 texel, vec2 uv, vec4 ssilvb) {
    vec4 center_color = texture(indirect_lighting_buffer, get_blur_coord(uv, 4));
    vec4 center_nor = texture(normal_buffer, get_blur_coord(uv, 4));
    float gaussian_total_weight = 0.18;
    vec4 sum = center_color * 0.18;

    float gaussian_weights[9] = float[](0.05, 0.09, 0.12, 0.15, 0.18, 0.15, 0.12, 0.09, 0.05);
    

    for (int i = 0; i < 9; ++i) {
        if (i == 4) {
            continue;
        }
        vec4 sample_color = texture(indirect_lighting_buffer, get_blur_coord(uv, i));
        vec4 sample_nor = texture(normal_buffer, get_blur_coord(uv, i));
        float normal_difference = distance(center_nor, sample_nor);
        float dist_from_center_color = min(normal_difference * params.edge_threshold, 1.0);
        float gaussian_weight = gaussian_weights[i] * (1.0 - dist_from_center_color);

        gaussian_total_weight += gaussian_weight;
        sum += sample_color * gaussian_weight;
    }

    return sum / gaussian_total_weight;
}


void main() {
    ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 half_texel = texel / 2;
    vec2 tex_coord = (vec2(texel) + 0.5) / vec2(push_params.screen_size);
    vec2 half_tex_coord = (vec2(texel) * 0.5 + 0.5) / vec2(push_params.screen_size * 0.5);

    vec4 raw_ssilvb = vec4(0.0);
    if(params.half_res) {
       raw_ssilvb = texture(indirect_lighting_buffer, half_tex_coord);
    } else {
        raw_ssilvb = texture(indirect_lighting_buffer, tex_coord);
    }

    vec4 color = texelFetch(color_buffer, texel, 0);
    raw_ssilvb = bilateral_blur(texel, tex_coord, raw_ssilvb);

    // You may be wondering, why in the world are we doing this crap with blur_dir? To answer that, keep in mind we are running this shader twice. So if we multiplied things like the gi by the intensity both times..
    // we are esentially on the second pass doing (gi * intensity) * intensity. To avoid that we make sure we are on the vertical/last pass.

    raw_ssilvb.rgb = (params.blur_dir == 0) ? raw_ssilvb.rgb : raw_ssilvb.rgb * params.gi_strength;

    if (params.blur_dir == 1) {
        color.rgb = color.rgb + raw_ssilvb.rgb;
        color.rgb = color.rgb * mix(1.0, raw_ssilvb.a, params.ao_strength);
    }

    vec4 final_color = params.blur_dir == 0 ? raw_ssilvb : color;

    imageStore(output_image, texel, final_color);
}