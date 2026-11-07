// Galaxy A04s, Metal track M1b: our own Metal shaders, compiled by Apple's Metal compiler on a
// macOS runner (the iPhoneOS SDK, MSL 3.0, iOS 16 deployment target, as iOS 16.7's own libraries
// are built) and fed through the AIR front end onto Panfrost as the Mali-G52.
//
// CORE: every function here must compile for the G52 and build job chains (check.sh fails if one
// does not). They cover what the compositor and the wallpaper path use most: buffer kernels,
// texture writes, threadgroup memory, half precision, a fragment shader reading its position, and
// a vertex/fragment pair with a varying and a sampled texture (the panel scaler's shape).

#include <metal_stdlib>
using namespace metal;

// A buffer fill: the "compute writes a buffer" of the plan's step 2.
kernel void fill_buffer(device uint *out [[buffer(0)]],
                        uint id [[thread_position_in_grid]])
{
    out[id] = id * 3u + 7u;
}

// Half precision, which iOS's own shaders use heavily (Bifrost has native FP16).
kernel void half_scale(device half4 *io [[buffer(0)]],
                       constant float &k [[buffer(1)]],
                       uint id [[thread_position_in_grid]])
{
    io[id] = io[id] * half(k) + half4(0.5h);
}

// A texture written by a kernel (as CoreImage's kernels do).
kernel void tex_gradient(texture2d<float, access::write> dst [[texture(0)]],
                         uint2 gid [[thread_position_in_grid]])
{
    float2 size = float2(dst.get_width(), dst.get_height());
    float2 uv = (float2(gid) + 0.5f) / size;
    dst.write(float4(uv.x, uv.y, 0.5f, 1.0f), gid);
}

// Threadgroup memory and a barrier: a per-group sum.
kernel void group_sum(device const float *in [[buffer(0)]],
                      device float *out [[buffer(1)]],
                      threadgroup float *scratch [[threadgroup(0)]],
                      uint lid [[thread_position_in_threadgroup]],
                      uint gid [[threadgroup_position_in_grid]],
                      uint tid [[thread_position_in_grid]],
                      uint n [[threads_per_threadgroup]])
{
    scratch[lid] = in[tid];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = n / 2; s > 0; s >>= 1) {
        if (lid < s)
            scratch[lid] += scratch[lid + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lid == 0)
        out[gid] = scratch[0];
}

// The 7c-4c gradient, as a Metal fragment shader: red across, green down.
fragment float4 gradient_fs(float4 pos [[position]])
{
    return float4(pos.x / 720.0f, pos.y / 1600.0f, 0.5f, 1.0f);
}

// A full-screen quad with a varying: the panel scaler's vertex stage.
struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

vertex QuadOut quad_vs(uint vid [[vertex_id]])
{
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    QuadOut o;
    o.position = float4(corners[vid], 0.0f, 1.0f);
    o.uv = corners[vid] * float2(0.5f, -0.5f) + 0.5f;
    return o;
}

fragment float4 uv_fs(QuadOut in [[stage_in]])
{
    return float4(in.uv, 0.0f, 1.0f);
}

// Sampling a texture through the quad's varying: the scaler's fragment stage (bilinear).
fragment float4 blit_fs(QuadOut in [[stage_in]],
                        texture2d<float> src [[texture(0)]],
                        sampler smp [[sampler(0)]])
{
    return src.sample(smp, in.uv);
}

// The same with a constexpr sampler, as QuartzCore's shaders declare theirs.
fragment float4 blit_const_fs(QuadOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]])
{
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    return src.sample(s, in.uv);
}
