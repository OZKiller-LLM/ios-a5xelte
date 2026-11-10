// Galaxy A04s, Metal track M5: the triangle of the plan's "compute, then a triangle", on the G52.
//
// A vertex stage reading its positions from a buffer by [[vertex_id]] and its colour from a
// constant buffer -- the shape of CoreAnimation's own vertex stages, which read buffers rather
// than vertex attributes -- and a fragment stage passing the colour through. The constant buffer
// in the vertex stage is the case libhakiosair moves up one Gallium slot on Panfrost (ubo_base).

#include <metal_stdlib>
using namespace metal;

struct TriOut {
    float4 position [[position]];
    float4 color;
};

vertex TriOut tri_vs(uint vid [[vertex_id]],
                     const device float2 *pos [[buffer(0)]],
                     constant float4 &color [[buffer(1)]])
{
    TriOut o;
    o.position = float4(pos[vid], 0.0f, 1.0f);
    o.color = color;
    return o;
}

fragment float4 tri_fs(TriOut in [[stage_in]])
{
    return in.color;
}

// Galaxy A04s, Metal track M6a run 7: the shape of QuartzCore's four-tap downsample, in our own
// words, to tell a sampling problem from one in CoreAnimation's inputs. The texture sits in slot 3
// and its sampler in slot 0 (slots 0-2 left empty), the tap offsets and half-precision weights come
// from a constant buffer at index 1 (the weights at byte 64 of 80) and a half scale from index 6,
// and the result is a half4: all as downsample_4_frag_lph declares them.
struct DsOut {
    float4 position [[position]];
    float2 uv;
};

vertex DsOut ds_quad_vs(uint vid [[vertex_id]])
{
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    DsOut o;
    o.position = float4(corners[vid], 0.0f, 1.0f);
    o.uv = corners[vid] * float2(0.5f, -0.5f) + 0.5f;
    return o;
}

struct DsTaps {
    float2 offset[4];   // bytes 0-31
    float4 unused[2];   // bytes 32-63
    half4 weight;       // bytes 64-71
    half4 unused2;      // bytes 72-79
};

fragment half4 ds_like_fs(DsOut in [[stage_in]],
                          texture2d<half> src [[texture(3)]],
                          sampler smp [[sampler(0)]],
                          constant DsTaps &taps [[buffer(1)]],
                          constant half &scale [[buffer(6)]])
{
    half4 acc = half4(0.0h);
    for (int k = 0; k < 4; k++)
        acc += src.sample(smp, in.uv + taps.offset[k], level(0)) * taps.weight[k];
    return half4(acc.rgb * scale, acc.a);
}

// M6a run 8: the interface of QuartzCore's downsample_blur_vert_lph + downsample_4_frag_lph,
// written here from its reflected shape (names, attribute and buffer indices) so each half can be
// paired with QuartzCore's other half on the phone. The varying is named texcoord0 so that it
// links with QuartzCore's fragment function as theirs does.
struct DsQOut {
    float4 position [[position]];
    float2 texcoord0;
};

vertex DsQOut ds_q_quad_vs(uint vid [[vertex_id]])
{
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    DsQOut o;
    o.position = float4(corners[vid], 0.0f, 1.0f);
    o.texcoord0 = corners[vid] * float2(0.5f, -0.5f) + 0.5f;
    return o;
}

struct DsQIn {
    float4 position [[attribute(0)]];
    float2 texcoord0 [[attribute(1)]];
    half4 color [[attribute(3)]];
};

vertex DsQOut ds_q_attr_vs(DsQIn in [[stage_in]],
                           constant float4x4 *mvp_matrix [[buffer(2)]],
                           constant float4 &texmat0 [[buffer(3)]])
{
    DsQOut o;
    o.position = mvp_matrix[0] * in.position;
    o.texcoord0 = in.texcoord0 * texmat0.xy + texmat0.zw;
    return o;
}

fragment half4 ds_q_fs(DsQOut in [[stage_in]],
                       texture2d<half> src [[texture(3)]],
                       sampler smp [[sampler(0)]],
                       constant DsTaps &taps [[buffer(1)]],
                       constant half &scale [[buffer(6)]])
{
    half4 acc = half4(0.0h);
    for (int k = 0; k < 4; k++)
        acc += src.sample(smp, in.texcoord0 + taps.offset[k], level(0)) * taps.weight[k];
    return half4(acc.rgb * scale, acc.a);
}
