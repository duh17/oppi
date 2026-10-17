#include <metal_stdlib>
using namespace metal;

struct CellInstance {
    float2 origin;
    float2 size;
    float4 color;
    float4 uv;
    uint flags;
    uint pad0;
    uint pad1;
    uint pad2;
};

struct Uniforms {
    float2 viewport;
};

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
    uint flags;
};

constant float2 kCorners[4] = {
    float2(0, 0),
    float2(1, 0),
    float2(0, 1),
    float2(1, 1),
};

vertex VertexOut ssh_terminal_vertex(
    uint vid [[vertex_id]],
    uint iid [[instance_id]],
    constant CellInstance *instances [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    CellInstance cell = instances[iid];
    float2 corner = kCorners[vid];
    float2 pixel = cell.origin + corner * cell.size;
    float2 ndc = float2(
        pixel.x / uniforms.viewport.x * 2.0 - 1.0,
        1.0 - pixel.y / uniforms.viewport.y * 2.0
    );
    VertexOut out;
    out.position = float4(ndc, 0, 1);
    out.color = cell.color;
    out.uv = mix(cell.uv.xy, cell.uv.zw, corner);
    out.flags = cell.flags;
    return out;
}

fragment float4 ssh_terminal_solid(VertexOut in [[stage_in]]) {
    return in.color;
}

fragment float4 ssh_terminal_glyph(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler nearest(mag_filter::nearest, min_filter::nearest, address::clamp_to_edge);
    float coverage = atlas.sample(nearest, in.uv).a;
    return float4(in.color.rgb * coverage, in.color.a * coverage);
}
