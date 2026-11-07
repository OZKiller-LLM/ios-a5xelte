// Galaxy A04s, Metal track M1b: PROBES. Features iOS 16's own shaders use that the path may not
// handle yet. check.sh records each result (compiled and chains built, or the front end's or
// Panfrost's refusal by name) but does not fail on them: they are the list of what to do next.

#include <metal_stdlib>
using namespace metal;

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

// The vertex stage for this library's --draw-vertex probes (core.metal's quad_vs, repeated).
vertex QuadOut quad_vs_p(uint vid [[vertex_id]])
{
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    QuadOut o;
    o.position = float4(corners[vid], 0.0f, 1.0f);
    o.uv = corners[vid] * float2(0.5f, -0.5f) + 0.5f;
    return o;
}

// Programmable blending (framebuffer fetch): QuartzCore's colour-reading fragments (p3_clamp
// and others) read the attachment like this. Bifrost can read its tile buffer.
fragment float4 fbfetch_fs(QuadOut in [[stage_in]], float4 dst [[color(0)]])
{
    return float4(dst.rgb * 0.5f, dst.a);
}

// A function constant, as QuartzCore's fixed_* shaders specialise.
constant bool use_red [[function_constant(0)]];

fragment float4 const_fs(QuadOut in [[stage_in]])
{
    return use_red ? float4(1, 0, 0, 1) : float4(in.uv, 0, 1);
}

// SIMD-group functions (CoreImage and MPS use them; the G52's warp is narrow).
kernel void simd_sum_k(device const float *in [[buffer(0)]],
                       device float *out [[buffer(1)]],
                       uint tid [[thread_position_in_grid]],
                       uint lane [[thread_index_in_simdgroup]])
{
    float s = simd_sum(in[tid]);
    if (lane == 0)
        out[tid] = s;
}

// Atomics on device memory.
kernel void atomic_count(device atomic_uint *counter [[buffer(0)]],
                         device const uint *flags [[buffer(1)]],
                         uint tid [[thread_position_in_grid]])
{
    if (flags[tid] != 0)
        atomic_fetch_add_explicit(counter, 1u, memory_order_relaxed);
}

// half in a fragment shader with a texture read (no sampler) -- read() of a texture2d<half>.
fragment half4 half_read_fs(QuadOut in [[stage_in]], texture2d<half> src [[texture(0)]])
{
    uint2 p = uint2(in.position.xy);
    return src.read(p) * 0.5h;
}
