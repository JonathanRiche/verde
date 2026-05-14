#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;
layout(location = 2) in vec2 in_pixel_pos;
layout(location = 3) in vec2 in_sdf_min;
layout(location = 4) in vec2 in_sdf_size;
layout(location = 5) in vec2 in_sdf_radius_border;
layout(location = 6) in vec4 in_sdf_border;

layout(location = 0) out vec4 out_color;

// Signed distance to an axis-aligned rounded rectangle centered at the origin
// with half-extents `b` and corner radius `r`. Negative inside, positive
// outside, exactly 0 on the geometric edge. (Inigo Quilez, "rounded box" SDF.)
float sdfRoundedRect(vec2 p, vec2 b, float r) {
    vec2 d = abs(p) - b + vec2(r);
    return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - r;
}

void main() {
    // Fast path for triangles and plain (non-rounded, non-bordered) rects: the
    // vertex SDF size is zero so we emit the flat color directly.
    if (in_sdf_size.x <= 0.0 || in_sdf_size.y <= 0.0) {
        out_color = in_color;
        return;
    }

    vec2 center = in_sdf_min + in_sdf_size * 0.5;
    vec2 half_size = in_sdf_size * 0.5;
    vec2 p = in_pixel_pos - center;
    float radius = in_sdf_radius_border.x;
    float border_w = in_sdf_radius_border.y;
    float dist = sdfRoundedRect(p, half_size, radius);

    // Pixel-coverage AA: smoothstep over a 1-px band straddling the geometric
    // edge. `fwidth` would give per-fragment derivative width but the UI is
    // rendered 1:1 (no NDC zoom) so a fixed 1-px band matches framebuffer
    // pixels exactly and avoids the noise fwidth introduces at glancing
    // angles.
    if (border_w > 0.0 && in_sdf_border.a > 0.0) {
        float outer_alpha = 1.0 - smoothstep(-0.5, 0.5, dist);
        float inner_alpha = 1.0 - smoothstep(-0.5, 0.5, dist + border_w);
        float border_alpha = max(outer_alpha - inner_alpha, 0.0);
        float fill_alpha = inner_alpha;

        vec4 fill = vec4(in_color.rgb, in_color.a * fill_alpha);
        float b_a = in_sdf_border.a * border_alpha;
        // Composite: border over fill.
        vec3 rgb = in_sdf_border.rgb * b_a + fill.rgb * (1.0 - b_a);
        float a = b_a + fill.a * (1.0 - b_a);
        out_color = vec4(rgb, a);
    } else {
        float alpha = 1.0 - smoothstep(-0.5, 0.5, dist);
        out_color = vec4(in_color.rgb, in_color.a * alpha);
    }
}
