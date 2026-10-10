// Palette instanced UI uber-shader, HLSL (SM 4.0) port of src/shaders/ui.vert.glsl and
// ui.frag.glsl. Keep the three files in step: same 64-byte instance (gpu/core.zig `Instance`),
// same maths, premultiplied output (blend ONE, INV_SRC_ALPHA).
//
// Compiled offline to ui_vs.dxbc / ui_ps.dxbc (checked in); see ../README.md.

cbuffer Push : register(b0) {
    float2 ndc_scale; // 2 / viewport
    uint flags;
    uint pad;
};

Texture2D<float> u_glyph_atlas : register(t0);  // R8 coverage
Texture2D<float4> u_color_atlas : register(t1); // RGBA8 premultiplied
Texture2D<float4> u_image : register(t2);       // RGBA8/BGRA8 straight alpha
SamplerState u_image_sampler : register(s0);    // trilinear, clamp

static const uint KIND_SDF = 1u;
static const uint KIND_TRIANGLE = 2u;
static const float SDF_HALO = 1.0;
static const uint FLAG_LEGACY_BORDER_BLEND = 1u;
static const uint FLAG_TRIANGLE_AA = 2u;

struct VsIn {
    float4 rect : RECT;  // x, y, w, h   (triangle: p0.xy, p1.xy)
    float4 clip : CLIP;  // x0, y0, x1, y1 in device px
    float4 uv : UV;      // u0, v0, u1, v1 (triangle: p2.xy)
    uint4 misc : MISC;   // fill rgba8, border rgba8, radius f32 bits, kind | border_px << 8
    uint vid : SV_VertexID;
};

struct VsOut {
    float4 pos : SV_Position;
    float2 uv : TEXCOORD0;
    nointerpolation float4 color : COLOR0;
    nointerpolation float4 border : COLOR1;
    nointerpolation float4 shape : TEXCOORD1; // sdf: center.xy, half.xy | triangle: p0.xy, p1.xy
    nointerpolation float4 extra : TEXCOORD2; // sdf: radius, border_w  | triangle: p2.xy
    nointerpolation uint kind : KIND;
};

float4 unpackUnorm4x8(uint v) {
    return float4(float(v & 255u), float((v >> 8) & 255u), float((v >> 16) & 255u), float(v >> 24)) / 255.0;
}

VsOut vs_main(VsIn i) {
    VsOut o;
    uint kind = i.misc.w & 0xffu;
    float2 corner = float2(float(i.vid & 1u), float(i.vid >> 1));
    float2 lo;
    float2 hi;
    if (kind == KIND_TRIANGLE) {
        float2 p2 = i.uv.xy;
        lo = min(min(i.rect.xy, i.rect.zw), p2) - SDF_HALO;
        hi = max(max(i.rect.xy, i.rect.zw), p2) + SDF_HALO;
        o.shape = i.rect;
        o.extra = float4(p2, 0.0, 0.0);
    } else {
        float halo = kind == KIND_SDF ? SDF_HALO : 0.0;
        lo = i.rect.xy - halo;
        hi = i.rect.xy + i.rect.zw + halo;
        float2 half_size = i.rect.zw * 0.5;
        o.shape = float4(i.rect.xy + half_size, half_size);
        o.extra = float4(asfloat(i.misc.z), float(i.misc.w >> 8), 0.0, 0.0);
    }
    lo = max(lo, i.clip.xy);
    hi = min(hi, i.clip.zw);
    hi = max(hi, lo); // empty intersection collapses to a zero-area quad

    float2 pos = lerp(lo, hi, corner);
    float2 t = (pos - i.rect.xy) / max(i.rect.zw, float2(1e-6, 1e-6));
    o.uv = lerp(i.uv.xy, i.uv.zw, t);
    o.color = unpackUnorm4x8(i.misc.x);
    o.border = unpackUnorm4x8(i.misc.y);
    o.kind = kind;
    // Device px (y down) -> D3D NDC (y up).
    float2 ndc = pos * ndc_scale - 1.0;
    o.pos = float4(ndc.x, -ndc.y, 0.0, 1.0);
    return o;
}

float sdfRoundedRect(float2 p, float2 b, float r) {
    float2 d = abs(p) - b + r;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

float4 premul(float4 c) {
    return float4(c.rgb * c.a, c.a);
}

float4 shadeSdfRect(VsOut i, float2 p) {
    float radius = i.extra.x;
    float border_w = i.extra.y;
    float dist = sdfRoundedRect(p - i.shape.xy, i.shape.zw, radius);
    const float aa = 0.75;
    if (border_w > 0.0 && i.border.a > 0.0) {
        float outer_alpha = 1.0 - smoothstep(-aa, aa, dist);
        float inner_alpha = 1.0 - smoothstep(-aa, aa, dist + border_w);
        float border_alpha = max(outer_alpha - inner_alpha, 0.0);
        float fill_a = i.color.a * inner_alpha;
        float b_a = i.border.a * border_alpha;
        float a = b_a + fill_a * (1.0 - b_a);
        if ((flags & FLAG_LEGACY_BORDER_BLEND) != 0u) {
            float3 rgb = i.border.rgb * b_a + i.color.rgb * (1.0 - b_a);
            return float4(rgb * a, a);
        }
        return float4(i.border.rgb * b_a + i.color.rgb * fill_a * (1.0 - b_a), a);
    }
    float alpha = 1.0 - smoothstep(-aa, aa, dist);
    return premul(float4(i.color.rgb, i.color.a * alpha));
}

float edgeDistance(float2 p, float2 a, float2 b, float orient) {
    float2 e = b - a;
    float len = length(e);
    if (len < 1e-6) return 1e6;
    float2 n = float2(e.y, -e.x) * (orient / len);
    return dot(p - a, n);
}

float4 shadeTriangle(VsOut i, float2 p) {
    float2 p0 = i.shape.xy;
    float2 p1 = i.shape.zw;
    float2 p2 = i.extra.xy;
    float2 e0 = p1 - p0;
    float2 e1 = p2 - p0;
    float area = e0.x * e1.y - e0.y * e1.x;
    if (abs(area) < 1e-6) discard;
    float orient = area > 0.0 ? -1.0 : 1.0;
    float d = min(edgeDistance(p, p0, p1, orient), min(edgeDistance(p, p1, p2, orient), edgeDistance(p, p2, p0, orient)));
    float coverage = (flags & FLAG_TRIANGLE_AA) != 0u ? saturate(d + 0.5) : step(0.0, d);
    return premul(float4(i.color.rgb, i.color.a * coverage));
}

float4 ps_main(VsOut i) : SV_Target {
    // SV_Position.xy is the pixel centre in target px (top-left origin), like gl_FragCoord
    // under Vulkan's upper-left convention.
    float2 p = i.pos.xy;
    if (i.kind == 0u) return premul(i.color);
    if (i.kind == 1u) return shadeSdfRect(i, p);
    if (i.kind == 2u) return shadeTriangle(i, p);
    int2 texel = int2(i.uv);
    if (i.kind == 3u) return float4(i.color.rgb, 1.0) * (i.color.a * u_glyph_atlas.Load(int3(texel, 0)));
    if (i.kind == 4u) return u_color_atlas.Load(int3(texel, 0)) * i.color.a;
    // `kind` is constant per primitive, so the 2x2 quad's derivatives stay well defined.
    return premul(u_image.Sample(u_image_sampler, i.uv) * i.color);
}
