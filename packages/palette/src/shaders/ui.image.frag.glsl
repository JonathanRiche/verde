#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;

layout(set = 2, binding = 0) uniform sampler2D image_texture;

layout(location = 0) out vec4 out_color;

void main() {
    out_color = texture(image_texture, in_uv) * in_color;
}
