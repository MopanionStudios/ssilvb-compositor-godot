#[compute]
#version 450

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform restrict writeonly image2D output_image;


// Buffers
layout(set = 0, binding = 1) uniform sampler2D indirect_lighting_buffer;
layout(set = 0, binding = 2) uniform sampler2D normal_buffer;
layout(set = 0, binding = 3) uniform sampler2D depth_buffer;
layout(set = 0, binding = 4) uniform sampler2D color_buffer;

layout(set = 1, binding = 0) uniform SceneParams {
    float depth_difference_threshold;
    float blur_intensity;
    float edge_threshold;
    float ao_strength;
    float gi_intensity;
    int blur_dir;
} params;


// Push constant
layout(push_constant, std430) uniform Params {
    ivec2 screen_size;
    float z_n;
    float z_f;
} push_params;


// Helper functions
vec3 normal_compatibility(vec3 p_normal) {
	return vec3(normalize(p_normal * 2.0 - 1.0) * 0.5 + 0.5);
}

float LinDepth_from_NonLinDepth(float depth)
{
    return push_params.z_n / (depth);
}

float NonLinDepth_from_LinDepth(float depth)
{
    return push_params.z_n / depth;
}


vec4 bilateral_blur(vec2 uv, vec4 center_color) {
    vec3 center_nor = normalize(normal_compatibility(texture(normal_buffer, uv).rgb) * 2.0 - 1.0);
    float center_depth = LinDepth_from_NonLinDepth(texture(depth_buffer, uv).r);

    vec2 p_size = 1.0 / vec2(push_params.screen_size);
    vec2 offset = params.blur_dir == 0 ? vec2(params.blur_intensity * p_size.x, 0.0) : vec2(0.0, params.blur_intensity * p_size.y);

    float weights[11] = float[](
            0.05, 0.05, 0.09, 0.12, 0.15, 0.18, 0.15, 0.12, 0.09, 0.05, 0.05
    );

    int radius = 5;

    float gaussian_total_weight = weights[radius];
    vec4 sum = center_color * gaussian_total_weight;
    

    for (int i = -radius; i <= radius; ++i) {
        if (i == 0) continue;

        vec2 sample_uv = uv + float(i) * offset;
        
        vec4 sample_color = texture(indirect_lighting_buffer, sample_uv);
        vec3 sample_nor = normalize(normal_compatibility(texture(normal_buffer, sample_uv).rgb) * 2.0 - 1.0);
        
        if (dot(sample_nor, center_nor) >= params.edge_threshold) {

            float sample_depth = LinDepth_from_NonLinDepth(texture(depth_buffer, sample_uv).r);

            if (abs(sample_depth - center_depth) <= params.depth_difference_threshold) {
                float gaussian_weight = weights[i + radius];
                gaussian_total_weight += gaussian_weight;
                sum += gaussian_weight * sample_color;
            }
        }
    }

    return sum / gaussian_total_weight;
}


void main() {
    ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
    vec2 tex_coord = (vec2(texel) + 0.5) / vec2(push_params.screen_size);

    vec4 raw_ssilvb = texture(indirect_lighting_buffer, tex_coord);
    raw_ssilvb = bilateral_blur(tex_coord, raw_ssilvb);

    vec4 color = texture(color_buffer, tex_coord);

    // You may be wondering, why in the world are we doing this crap with blur_dir? To answer that, keep in mind we are running this shader twice. So if we multiplied things like the gi by the intensity both times..
    // we are esentially on the second pass doing (gi * intensity) * intensity. To avoid that we make sure we are on the vertical/last pass.

    raw_ssilvb.rgb = (params.blur_dir == 0) ? raw_ssilvb.rgb : raw_ssilvb.rgb * params.gi_intensity;

    if (params.blur_dir == 1) {
        color.rgb = color.rgb + raw_ssilvb.rgb;
        color.rgb = color.rgb * mix(1.0, raw_ssilvb.a, params.ao_strength);
    }

    vec4 final_color = params.blur_dir == 0 ? raw_ssilvb : color;

    imageStore(output_image, texel, final_color);
}