#version 450
// Palette uber fragment shader. Output is premultiplied alpha (blend ONE, ONE_MINUS_SRC_ALPHA),
// which is exactly equivalent to the old renderer's straight-alpha blend state
// (colour SRC_ALPHA/ONE_MINUS_SRC_ALPHA, alpha ONE/ONE_MINUS_SRC_ALPHA).

layout(location = 0) in vec2 v_uv;
layout(location = 1) flat in vec4 v_color;
layout(location = 2) flat in vec4 v_border;
layout(location = 3) flat in vec4 v_shape;
layout(location = 4) flat in vec4 v_extra;
layout(location = 5) flat in uint v_kind;

layout(set = 0, binding = 0) uniform sampler2D u_glyph_atlas; // R8 coverage
layout(set = 0, binding = 1) uniform sampler2D u_color_atlas; // RGBA8 premultiplied
layout(set = 1, binding = 0) uniform sampler2D u_image;       // RGBA8 straight alpha

layout(push_constant) uniform Push {
    vec2 ndc_scale;
    uint flags;
    uint pad;
} pc;

layout(location = 0) out vec4 o_color;

const uint FLAG_LEGACY_BORDER_BLEND = 1u;
const uint FLAG_TRIANGLE_AA = 2u;

// Inigo Quilez rounded box SDF; identical to the old ui.solid.frag.glsl.
float sdfRoundedRect(vec2 p, vec2 b, float r) {
    vec2 d = abs(p) - b + vec2(r);
    return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - r;
}

vec4 premul(vec4 c) {
    return vec4(c.rgb * c.a, c.a);
}

vec4 shadeSdfRect(vec2 p) {
    float radius = v_extra.x;
    float border_w = v_extra.y;
    float dist = sdfRoundedRect(p - v_shape.xy, v_shape.zw, radius);
    // Blend across 1.5 framebuffer pixels (old renderer: smooths small-radius corners
    // without moving the geometric edge).
    const float aa = 0.75;
    if (border_w > 0.0 && v_border.a > 0.0) {
        float outer_alpha = 1.0 - smoothstep(-aa, aa, dist);
        float inner_alpha = 1.0 - smoothstep(-aa, aa, dist + border_w);
        float border_alpha = max(outer_alpha - inner_alpha, 0.0);
        float fill_a = v_color.a * inner_alpha;
        float b_a = v_border.a * border_alpha;
        float a = b_a + fill_a * (1.0 - b_a);
        if ((pc.flags & FLAG_LEGACY_BORDER_BLEND) != 0u) {
            // Old renderer, bit-for-bit: straight colours mixed by border alpha only.
            vec3 rgb = v_border.rgb * b_a + v_color.rgb * (1.0 - b_a);
            return vec4(rgb * a, a);
        }
        // Premultiplied "border over fill".
        return vec4(v_border.rgb * b_a + v_color.rgb * fill_a * (1.0 - b_a), a);
    }
    float alpha = 1.0 - smoothstep(-aa, aa, dist);
    return premul(vec4(v_color.rgb, v_color.a * alpha));
}

float edgeDistance(vec2 p, vec2 a, vec2 b, float orient) {
    vec2 e = b - a;
    float len = length(e);
    if (len < 1e-6) return 1e6;
    vec2 n = vec2(e.y, -e.x) * (orient / len);
    return dot(p - a, n);
}

vec4 shadeTriangle(vec2 p) {
    vec2 p0 = v_shape.xy;
    vec2 p1 = v_shape.zw;
    vec2 p2 = v_extra.xy;
    vec2 e0 = p1 - p0;
    vec2 e1 = p2 - p0;
    float area = e0.x * e1.y - e0.y * e1.x;
    if (abs(area) < 1e-6) discard;
    float orient = area > 0.0 ? -1.0 : 1.0;
    float d = min(edgeDistance(p, p0, p1, orient), min(edgeDistance(p, p1, p2, orient), edgeDistance(p, p2, p0, orient)));
    float coverage = (pc.flags & FLAG_TRIANGLE_AA) != 0u ? clamp(d + 0.5, 0.0, 1.0) : step(0.0, d);
    return premul(vec4(v_color.rgb, v_color.a * coverage));
}

void main() {
    vec2 p = gl_FragCoord.xy;
    switch (v_kind) {
        case 0u: // flat quad
            o_color = premul(v_color);
            break;
        case 1u:
            o_color = shadeSdfRect(p);
            break;
        case 2u:
            o_color = shadeTriangle(p);
            break;
        case 3u: // coverage glyph; uv in atlas texels (atlases may grow mid-frame)
            o_color = vec4(v_color.rgb, 1.0) * (v_color.a * texelFetch(u_glyph_atlas, ivec2(v_uv), 0).r);
            break;
        case 4u: // colour glyph (premultiplied bitmap), tinted by alpha only
            o_color = texelFetch(u_color_atlas, ivec2(v_uv), 0) * v_color.a;
            break;
        default: // image: straight alpha * tint
            o_color = premul(texture(u_image, v_uv) * v_color);
            break;
    }
}
