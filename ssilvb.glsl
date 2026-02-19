#[compute]
#version 450

// Adapted from this lovely post https://www.shadertoy.com/view/XfcBDl

// Invocations in the (x, y, z) dimension
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform restrict writeonly image2D output_image;


// Buffers
layout(set = 0, binding = 1) uniform sampler2D color_buffer;
layout(set = 0, binding = 2) uniform sampler2D depth_buffer;
layout(set = 0, binding = 3) uniform sampler2D normal_buffer;

layout(set = 1, binding = 0) uniform uniformBuffer {
    mat4 proj;
    mat4 inv_proj;
} matrices;

layout(set = 2, binding = 0) uniform SceneParams {
    float gi_intensity;
    float radius;
    float thickness;
    int samples;
    int slices;
    bool half_res;
    bool temporal;
    bool backface_rejection;
} gi_params;


// Push constant
layout(push_constant, std430) uniform Params {
    ivec2 screen_size;
    float z_n; // Camera z_near clip value
    float z_f; // Camera z_far clip value
    uint frame_count;
} params;


// Constants
const float pi = 3.14159265359;
const float rPhif1 = 0.6180340;
const vec2  rPhif2 = vec2(0.7548777, 0.5698403);
const vec3  rPhif3 = vec3(0.8191725, 0.6710436, 0.5497005);
const vec4  rPhif4 = vec4(0.8566749, 0.7338919, 0.6287067, 0.5385973);

const uint  rPhi1 = 2654435769u;
const uvec2 rPhi2 = uvec2(3242174889u, 2447445413u);
const uvec3 rPhi3 = uvec3(3518319153u, 2882110345u, 2360945575u);
const uvec4 rPhi4 = uvec4(3679390609u, 3152041523u, 2700274805u, 2313257605u);

// Projection conversions

float LinDepth_from_NonLinDepth(float depth)
{
    return params.z_n / (depth);
}

float NonLinDepth_from_LinDepth(float depth)
{
    return params.z_n / depth;
}

vec4 PPos_from_VPos(vec3 vpos) {
    return matrices.proj * vec4(vpos, 1.0);
}

vec3 VPos_from_SPos(vec3 spos) {
    
    vec2 uv = spos.xy / vec2(params.screen_size) * 2.0 - 1.0;
    float depth = spos.z;
    // depth by default is nonlinear, so we dont need to convert it here
    vec4 p_pos = vec4(uv, depth, 1.0);
    vec4 view_pos = matrices.inv_proj * p_pos;
    view_pos /= view_pos.w;
    
    return view_pos.xyz;
}

vec3 viewspace_to_screenspace(vec3 vpos) {
    vec4 p_pos = PPos_from_VPos(vpos);
    vec2 ndc = p_pos.xy / p_pos.w;
    vec2 uv = (ndc * 0.5 + 0.5) * vec2(params.screen_size);
    
    return vec3(uv, vpos.z);
}

vec3 clipspace_to_viewspace(vec2 tex_coord, float raw_depth) {
    vec2 ndc_uv = tex_coord * 2.0 - 1.0;
    // pretty sure we want nonlinear depth here, judging by the fact i named this raw_depth when I made it.
    vec4 clipspace = vec4(ndc_uv, raw_depth, 1.0);
    vec4 viewspace = matrices.inv_proj * clipspace;
    return viewspace.xyz / viewspace.w;
}

// Quaternion utils

vec4 GetQuaternion(vec3 from, vec3 to) {
    vec3 xyz = cross(from, to);
    float s = dot(from, to);

    float u = inversesqrt(max(0.0, s * 0.5 + 0.5)); // rcp(cosine half-angle formula)
    
    s = 1.0 / u;
    xyz *= u * 0.5;

    return vec4(xyz, s);  
}

vec4 GetQuaternion(vec3 to) {
    //vec3 from = vec3(0.0, 0.0,-1.0);

    vec3 xyz = vec3( to.y,-to.x, 0.0); // cross(from, to);
    float s = -to.z; // dot(from, to);

    float u = inversesqrt(max(0.0, s * 0.5 + 0.5)); // rcp(cosine half-angle formula)
    
    s = 1.0 / u;
    xyz *= u * 0.5;

    return vec4(xyz, s);  
}

// transform v by unit quaternion q.xyzs
vec3 Transform(vec3 v, vec4 q) {
    vec3 k = cross(q.xyz, v);
    
    return v + 2.0 * vec3(dot(vec3(q.wy, -q.z), k.xzy),
                          dot(vec3(q.wz, -q.x), k.yxz),
                          dot(vec3(q.wx, -q.y), k.zyx));
}

// transform v by unit quaternion q.xy0s
vec3 Transform_Qz0(vec3 v, vec4 q) {
    float k = v.y * q.x - v.x * q.y;
    float g = 2.0 * (v.z * q.w + k);
    
    vec3 r;
    r.xy = v.xy + q.yx * vec2(g, -g);
    r.z  = v.z  + 2.0 * (q.w * k - v.z * dot(q.xy, q.xy));
    
    return r;
}

// transform v.xy0 by unit quaternion q.xy0s
vec3 Transform_Vz0Qz0(vec2 v, vec4 q) {
    float o = q.x * v.y;
    float c = q.y * v.x;
    
    vec3 b = vec3( o - c,
                  -o + c,
                   o - c);
    
    return vec3(v, 0.0) + 2.0 * (b * q.yxw);
}

// Helper functions
vec3 normal_compatibility(vec3 p_normal) {
	return vec3(normalize(p_normal * 2.0 - 1.0) * 0.5 + 0.5);
}

uint count_bits(uint v)
{
    v = v - ((v >> 1u) & 0x55555555u);
    v = (v & 0x33333333u) + ((v >> 2u) & 0x33333333u);
    return ((v + (v >> 4u) & 0xF0F0F0Fu) * 0x1010101u) >> 24u;
}

// noise

float ign(ivec2 pixel, uint n) {
    
    float offset = float(n);

    float x = float(pixel.x) + 5.588238f * offset;
    float y = float(pixel.y) + 5.588238f * offset;

    float rnd01 = mod(52.9829189 * mod(0.06711056 * x + 0.00583715 * y, 1.0), 1.0);

    return rnd01;
}

vec2 ign_01x4(ivec2 pixel, uint n) {
    return vec2(ign(pixel, n), ign(pixel, n + 1u));
}

// rnd01.x/rnd01.xy -> used to sample a slice direction (exact importance sampling needs 2 rnd numbers)
// rnd01.z -> used to jitter sample positions along ray marching direction
// rnd01.w -> used to jitter sample positions radially around slice normal
vec4 rnd01x4(ivec2 pixel, uint n) {
    vec4 rnd01 = vec4(0.0);

    rnd01.x = ign(pixel, n);
    rnd01.zw = ign_01x4(pixel, n + 1u);

    return rnd01;
}

vec4 ssilvb(vec2 uv0, float raw_depth, vec3 nor) {
    

    vec3 vs_pos = clipspace_to_viewspace(uv0, raw_depth);
    vec3 vs_normal = normalize(nor * 2.0 - 1.0);
    
    vec3 v = -normalize(vs_pos);
    
    vec2 ray_start = viewspace_to_screenspace(vs_pos).xy;
    
    float ao = 0.0;
    vec3 gi = vec3(0.0);

    uint dir_count = uint(gi_params.slices);
    uint frame = gi_params.temporal ? params.frame_count % 64 : 0u;
    
    for (uint i = 0u; i < dir_count; ++i) {
        uint n = frame * dir_count + i;
        vec4 rnd01 = rnd01x4(ivec2((uv0) * vec2(params.screen_size)), n);
        
        vec3 sample_dir_vs;
        vec2 dir;
        
        dir = vec2(cos(rnd01.x * pi), sin(rnd01.x * pi));
        sample_dir_vs = vec3(dir, vs_pos.z);
        
        vec4 q_to_v = GetQuaternion(v);
        sample_dir_vs = Transform_Vz0Qz0(dir, q_to_v);
        
        vec3 ray_start_vc3 = vec3(ray_start, vs_pos.z);
        vec3 ray_end = viewspace_to_screenspace(vs_pos + sample_dir_vs * (params.z_n * 0.5));
        
        vec3 ray_dir = ray_end - ray_start_vc3;
        ray_dir /= length(ray_dir.xy);
        
        dir = ray_dir.xy;
        
        // Slice construction
        vec3 slice_n = cross(v, sample_dir_vs);
        vec3 proj_n = vs_normal - slice_n * dot(vs_normal, slice_n);
        vec3 t = cross(slice_n, proj_n);
        
        float proj_n_sqr_len = dot(proj_n, proj_n);
        if(proj_n_sqr_len == 0.0) return vec4(0.0, 0.0, 0.0, 1.0);
        
        float proj_nr_cp_len = inversesqrt(proj_n_sqr_len);
        float cos_n = dot(proj_n, v) * proj_nr_cp_len;
        float sin_n = dot(t, v) * proj_nr_cp_len;
        
        vec3 gi0 = vec3(0.0);
        uint occ_bits = 0u;
        
        for (float d = -1.0; d <= 1.0; d += 2.0) {
            vec2 ray_dir0 = dir * d;
            
            uint count = uint(gi_params.samples);
            
            const float s = pow(gi_params.radius * 50.0, 1.0 / float(count));
            
            float t1 = pow(s, rnd01.z);
            rnd01.z = 1.0 - rnd01.z;
            
            for (float i = 0.0; i < count; ++i) {
                vec2 sample_pos = ray_start + ray_dir0 * t1;
                
                t1 *= s;
                
                if (sample_pos.x < 0.0 || sample_pos.x >= float(params.screen_size.x) || 
                    sample_pos.y < 0.0 || sample_pos.y >= float(params.screen_size.y)) break;
                
                vec2 sample_uv = sample_pos / vec2(params.screen_size);
                
                vec3 sample_direct = texture(color_buffer, sample_uv).rgb;
                float sample_depth = texture(depth_buffer, sample_uv).r;
                
                // Get view-space position
                vec3 sample_pos_vs = clipspace_to_viewspace(sample_uv, sample_depth);
                
                vec3 delta_pos_front = sample_pos_vs - vs_pos;
                vec3 delta_pos_back = delta_pos_front + normalize(sample_pos_vs) * gi_params.thickness;
                
                // Normalize to get horizon angles
                vec2 hor_cos = vec2(
                    dot(normalize(delta_pos_front), v), 
                    dot(normalize(delta_pos_back), v)
                );
                
                hor_cos = d >= 0.0 ? hor_cos.xy : hor_cos.yx;
                
                float d05 = d * 0.5;
                vec2 hor01 = ((0.5 + 0.5 * sin_n) + d05) - d05 * hor_cos;
                hor01 = clamp(hor01 + rnd01.w * (1.0 / 32.0), 0.0, 1.0);
                
                uvec2 hor_int = uvec2(floor(hor01 * 32.0));
                uint OxFFFFFFFFu = 0xFFFFFFFFu;
                
                uint m_x = hor_int.x < 32u ? OxFFFFFFFFu << hor_int.x : 0u;
                uint m_y = hor_int.y != 0u ? OxFFFFFFFFu >> (32u - hor_int.y) : 0u;
                
                uint occ_bits0 = m_x & m_y;
                uint vis_bits0 = occ_bits0 & (~occ_bits);
                
                if (vis_bits0 != 0u) {

                    if (gi_params.backface_rejection) {
                        vec3 n0 = normalize(normal_compatibility(texture(normal_buffer, sample_uv).rgb) * 2.0 - 1.0);

                        vec3 proj_n0 = n0 - slice_n * dot(n0, slice_n);
                        float proj_n0_sqr_len = dot(proj_n0, proj_n0);

                        if (proj_n0_sqr_len != 0.0) {
                            float proj_n0r_cp_len = inversesqrt(proj_n0_sqr_len);

                            float n_1 = proj_nr_cp_len * proj_n0r_cp_len;

                            float sin_phi = dot(proj_n, proj_n0) * n_1;
                            float cos_phi = dot(t, proj_n0) * n_1;

                            bool flip_t = cos_phi < 0.0;

                            sin_phi = !flip_t ? -sin_phi : sin_phi;

                            bool c = sin_phi > sin_n;

                            float m0 = c ? 1.0 : 0.0;
                            float m1 = c ? -0.5 : 0.5;

                            float hor_01 = m0 + m1 * (cos_n * abs(cos_phi) + sin_n * sin_phi) + (0.5 * sin_n);
                            hor_01 = clamp(hor_01 + rnd01.w * (1.0 / 32.0), 0.0, 1.0);

                            uint hor_int_0 = uint(floor(hor_01 * 32.0));
                            uint vis_bits_n = hor_int_0 < 32u ? 0xFFFFFFFFu << hor_int_0 : 0u;

                            vis_bits_n = !flip_t ? ~vis_bits_n : vis_bits_n;

                            vis_bits0 = vis_bits0 & vis_bits_n;
                        }
                    }

                    float vis0 = float(count_bits(vis_bits0)) * (1.0 / 32.0);
                    gi0 += sample_direct * vis0;
                }
                
                occ_bits = occ_bits | occ_bits0;
            }
        }
        
        float occ0 = float(count_bits(occ_bits)) * (1.0 / 32.0);
        ao += 1.0 - occ0;
        gi += gi0;
    }
    
    float norm = 1.0 / float(gi_params.slices);
    return vec4(gi, ao) * norm;
}


void main() {
    uvec2 texel = gl_GlobalInvocationID.xy;
    ivec2 itex = ivec2(texel);

    vec2 uv0 = (vec2(texel) + 0.5) / vec2(params.screen_size);

    vec4 lighting;
    float depth = LinDepth_from_NonLinDepth(texture(depth_buffer, uv0).r);

    if (depth <= 0.001) {
        imageStore(output_image, itex, vec4(0.0, 0.0, 0.0, 1.0));
    } else {
        vec3 normal = texture(normal_buffer, uv0).rgb;
        normal = normal_compatibility(normal);

        lighting = ssilvb(uv0, NonLinDepth_from_LinDepth(depth), normal);

        imageStore(output_image, itex, lighting);
    }
}