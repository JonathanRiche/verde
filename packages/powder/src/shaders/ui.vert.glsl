#version 450

layout(location = 0) in vec2 in_position;
layout(location = 1) in vec2 in_uv;
layout(location = 2) in vec4 in_color;

layout(location = 0) out vec2 out_uv;
layout(location = 1) out vec4 out_color;

layout(set = 1, binding = 0) uniform PowderUniforms {
    vec2 viewport_size;
    vec2 padding;
};

void main() {
    vec2 ndc = (in_position / viewport_size) * vec2(2.0, -2.0) + vec2(-1.0, 1.0);
    gl_Position = vec4(ndc, 0.0, 1.0);
    out_uv = in_uv;
    out_color = in_color;
}
