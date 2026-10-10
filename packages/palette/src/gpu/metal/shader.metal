// Palette uber-shader, Metal Shading Language port of src/shaders/ui.vert.glsl and
// ui.frag.glsl. Compiled at runtime (`-[MTLDevice newLibraryWithSource:]`), so no Metal
// toolchain is needed to build. Keep the maths in lockstep with the GLSL: the goldens are
// shared between backends.
//
// Differences from the Vulkan version, all mechanical:
// - instances are read from a buffer by [[instance_id]] (which includes the base instance)
//   instead of per-instance vertex attributes;
// - Metal NDC has +y up, so y is flipped in the vertex shader (framebuffer coordinates,
//   [[position]] in the fragment shader, are top-left origin with pixel centres at .5 like
//   gl_FragCoord in Vulkan);
// - samplers are constexpr in the shader (no sampler objects);
// - `clear_vertex`/`clear_fragment` replace vkCmdClearAttachments for partial redraws.
#include <metal_stdlib>
using namespace metal;

struct Instance {
    float4 rect; // x, y, w, h   (triangle: p0.xy, p1.xy)
    float4 clip; // x0, y0, x1, y1 in device px
    float4 uv;   // u0, v0, u1, v1 (triangle: p2.xy, -, -)
    uint4 misc;  // fill rgba8, border rgba8, radius f32 bits, kind | border_px << 8
};

struct Push {
    float2 ndc_scale; // 2 / viewport
    uint flags;
    uint pad;
};

struct VOut {
    float4 position [[position]];
    float2 uv;
    float4 color [[flat]];
    float4 border [[flat]];
    float4 shape [[flat]]; // sdf: center.xy, half.xy | triangle: p0.xy, p1.xy
    float4 extra [[flat]]; // sdf: radius, border_w  | triangle: p2.xy
    uint kind [[flat]];
};

constant uint KIND_SDF = 1u;
constant uint KIND_TRIANGLE = 2u;
constant float SDF_HALO = 1.0;
constant uint FLAG_LEGACY_BORDER_BLEND = 1u;
constant uint FLAG_TRIANGLE_AA = 2u;

vertex VOut ui_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                      const device Instance *instances [[buffer(0)]],
                      constant Push &pc [[buffer(1)]]) {
    Instance inst = instances[iid];
    VOut o;
    uint kind = inst.misc.w & 0xffu;
    float2 corner = float2(float(vid & 1u), float(vid >> 1));

    float2 lo;
    float2 hi;
    if (kind == KIND_TRIANGLE) {
        float2 p2 = inst.uv.xy;
        lo = min(min(inst.rect.xy, inst.rect.zw), p2) - float2(SDF_HALO);
        hi = max(max(inst.rect.xy, inst.rect.zw), p2) + float2(SDF_HALO);
        o.shape = inst.rect;
        o.extra = float4(p2, 0.0, 0.0);
    } else {
        float halo = kind == KIND_SDF ? SDF_HALO : 0.0;
        lo = inst.rect.xy - float2(halo);
        hi = inst.rect.xy + inst.rect.zw + float2(halo);
        float2 half_size = inst.rect.zw * 0.5;
        o.shape = float4(inst.rect.xy + half_size, half_size);
        o.extra = float4(as_type<float>(inst.misc.z), float(inst.misc.w >> 8), 0.0, 0.0);
    }
    lo = max(lo, inst.clip.xy);
    hi = min(hi, inst.clip.zw);
    hi = max(hi, lo); // empty intersection collapses to a zero-area quad

    float2 pos = mix(lo, hi, corner);
    float2 t = (pos - inst.rect.xy) / max(inst.rect.zw, float2(1e-6));
    o.uv = mix(inst.uv.xy, inst.uv.zw, t);
    o.color = unpack_unorm4x8_to_float(inst.misc.x);
    o.border = unpack_unorm4x8_to_float(inst.misc.y);
    o.kind = kind;
    float2 ndc = pos * pc.ndc_scale - 1.0;
    o.position = float4(ndc.x, -ndc.y, 0.0, 1.0);
    return o;
}

// Inigo Quilez rounded box SDF; identical to the GLSL.
static float sdfRoundedRect(float2 p, float2 b, float r) {
    float2 d = abs(p) - b + float2(r);
    return length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0) - r;
}

static float4 premul(float4 c) {
    return float4(c.rgb * c.a, c.a);
}

static float4 shadeSdfRect(VOut in, float2 p, uint flags) {
    float radius = in.extra.x;
    float border_w = in.extra.y;
    float dist = sdfRoundedRect(p - in.shape.xy, in.shape.zw, radius);
    const float aa = 0.75;
    if (border_w > 0.0 && in.border.a > 0.0) {
        float outer_alpha = 1.0 - smoothstep(-aa, aa, dist);
        float inner_alpha = 1.0 - smoothstep(-aa, aa, dist + border_w);
        float border_alpha = max(outer_alpha - inner_alpha, 0.0);
        float fill_a = in.color.a * inner_alpha;
        float b_a = in.border.a * border_alpha;
        float a = b_a + fill_a * (1.0 - b_a);
        if ((flags & FLAG_LEGACY_BORDER_BLEND) != 0u) {
            float3 rgb = in.border.rgb * b_a + in.color.rgb * (1.0 - b_a);
            return float4(rgb * a, a);
        }
        return float4(in.border.rgb * b_a + in.color.rgb * fill_a * (1.0 - b_a), a);
    }
    float alpha = 1.0 - smoothstep(-aa, aa, dist);
    return premul(float4(in.color.rgb, in.color.a * alpha));
}

static float edgeDistance(float2 p, float2 a, float2 b, float orient) {
    float2 e = b - a;
    float len = length(e);
    if (len < 1e-6) return 1e6;
    float2 n = float2(e.y, -e.x) * (orient / len);
    return dot(p - a, n);
}

fragment float4 ui_fragment(VOut in [[stage_in]],
                            constant Push &pc [[buffer(1)]],
                            texture2d<float> glyph_atlas [[texture(0)]],
                            texture2d<float> color_atlas [[texture(1)]],
                            texture2d<float> image [[texture(2)]]) {
    constexpr sampler image_sampler(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 p = in.position.xy;
    switch (in.kind) {
        case 0u: // flat quad
            return premul(in.color);
        case 1u:
            return shadeSdfRect(in, p, pc.flags);
        case 2u: {
            float2 p0 = in.shape.xy;
            float2 p1 = in.shape.zw;
            float2 p2 = in.extra.xy;
            float2 e0 = p1 - p0;
            float2 e1 = p2 - p0;
            float area = e0.x * e1.y - e0.y * e1.x;
            if (abs(area) < 1e-6) discard_fragment();
            float orient = area > 0.0 ? -1.0 : 1.0;
            float d = min(edgeDistance(p, p0, p1, orient), min(edgeDistance(p, p1, p2, orient), edgeDistance(p, p2, p0, orient)));
            float coverage = (pc.flags & FLAG_TRIANGLE_AA) != 0u ? clamp(d + 0.5, 0.0, 1.0) : step(0.0, d);
            return premul(float4(in.color.rgb, in.color.a * coverage));
        }
        case 3u: // coverage glyph; uv in atlas texels (atlases may grow mid-frame)
            return float4(in.color.rgb, 1.0) * (in.color.a * glyph_atlas.read(uint2(int2(in.uv))).r);
        case 4u: // colour glyph (premultiplied bitmap), tinted by alpha only
            return color_atlas.read(uint2(int2(in.uv))) * in.color.a;
        default: // image: straight alpha * tint
            return premul(image.sample(image_sampler, in.uv) * in.color);
    }
}

// Partial redraw: fills the scissored damage rects with the clear colour (no blending).
vertex float4 clear_vertex(uint vid [[vertex_id]]) {
    float2 c = float2(float(vid & 1u), float(vid >> 1));
    return float4(c * 2.0 - 1.0, 0.0, 1.0);
}

fragment float4 clear_fragment(constant float4 &color [[buffer(0)]]) {
    return color;
}
