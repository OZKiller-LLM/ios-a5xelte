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
