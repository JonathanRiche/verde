#version 450

layout(location = 0) in vec2 in_position;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color;
layout(location = 3) in vec2 in_sdf_min;
layout(location = 4) in vec2 in_sdf_size;
layout(location = 5) in vec2 in_sdf_radius_border;
layout(location = 6) in vec4 in_sdf_border;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;
layout(location = 2) out vec2 out_pixel_pos;
layout(location = 3) out vec2 out_sdf_min;
layout(location = 4) out vec2 out_sdf_size;
layout(location = 5) out vec2 out_sdf_radius_border;
layout(location = 6) out vec4 out_sdf_border;

layout(set = 1, binding = 0) uniform PaletteUniforms {
    vec2 viewport_size;
    vec2 padding;
};

void main() {
    vec2 ndc = (in_position / viewport_size) * vec2(2.0, -2.0) + vec2(-1.0, 1.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
    out_uv = in_uv;
    out_color = in_color;
    out_pixel_pos = in_position;
    out_sdf_min = in_sdf_min;
    out_sdf_size = in_sdf_size;
    out_sdf_radius_border = in_sdf_radius_border;
    out_sdf_border = in_sdf_border;
}
