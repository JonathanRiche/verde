#version 450
// Palette instanced UI vertex shader. One instance = one quad (4-vertex triangle strip).
// Geometry is clipped to the instance clip rect here, so the fragment shader never tests
// clips and fully clipped instances rasterize nothing. Layout must match gpu/renderer.zig
// `Instance`.

layout(location = 0) in vec4 i_rect;  // x, y, w, h   (triangle: p0.xy, p1.xy)
layout(location = 1) in vec4 i_clip;  // x0, y0, x1, y1 in device px
layout(location = 2) in vec4 i_uv;    // u0, v0, u1, v1 (triangle: p2.xy, -, -)
layout(location = 3) in uvec4 i_misc; // fill rgba8, border rgba8, radius f32 bits, kind | border_px << 8

layout(push_constant) uniform Push {
    vec2 ndc_scale; // 2 / viewport
    uint flags;
    uint pad;
} pc;

layout(location = 0) out vec2 v_uv;
layout(location = 1) flat out vec4 v_color;
layout(location = 2) flat out vec4 v_border;
layout(location = 3) flat out vec4 v_shape;  // sdf: center.xy, half.xy | triangle: p0.xy, p1.xy
layout(location = 4) flat out vec4 v_extra;  // sdf: radius, border_w  | triangle: p2.xy
layout(location = 5) flat out uint v_kind;

const uint KIND_SDF = 1u;
const uint KIND_TRIANGLE = 2u;
// The old renderer expands SDF quads by one pixel so the outer AA fringe has fragments.
const float SDF_HALO = 1.0;

void main() {
    uint kind = i_misc.w & 0xffu;
    vec2 corner = vec2(float(gl_VertexIndex & 1), float(gl_VertexIndex >> 1));

    vec2 lo;
    vec2 hi;
    if (kind == KIND_TRIANGLE) {
        vec2 p2 = i_uv.xy;
        lo = min(min(i_rect.xy, i_rect.zw), p2) - vec2(SDF_HALO);
        hi = max(max(i_rect.xy, i_rect.zw), p2) + vec2(SDF_HALO);
        v_shape = i_rect;
        v_extra = vec4(p2, 0.0, 0.0);
    } else {
        float halo = kind == KIND_SDF ? SDF_HALO : 0.0;
        lo = i_rect.xy - vec2(halo);
        hi = i_rect.xy + i_rect.zw + vec2(halo);
        vec2 half_size = i_rect.zw * 0.5;
        v_shape = vec4(i_rect.xy + half_size, half_size);
        v_extra = vec4(uintBitsToFloat(i_misc.z), float(i_misc.w >> 8), 0.0, 0.0);
    }
    lo = max(lo, i_clip.xy);
    hi = min(hi, i_clip.zw);
    hi = max(hi, lo); // empty intersection collapses to a zero-area quad

    vec2 pos = mix(lo, hi, corner);
    vec2 t = (pos - i_rect.xy) / max(i_rect.zw, vec2(1e-6));
    v_uv = mix(i_uv.xy, i_uv.zw, t);
    v_color = unpackUnorm4x8(i_misc.x);
    v_border = unpackUnorm4x8(i_misc.y);
    v_kind = kind;
    gl_Position = vec4(pos * pc.ndc_scale - 1.0, 0.0, 1.0);
}
