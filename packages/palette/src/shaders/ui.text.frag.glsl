#version 450

layout(location = 0) in vec2 in_uv;
layout(location = 1) in vec4 in_color;

layout(set = 2, binding = 0) uniform sampler2D font_atlas;

layout(location = 0) out vec4 out_color;

void main() {
    float alpha = texture(font_atlas, in_uv).a;
    out_color = vec4(in_color.rgb, in_color.a * alpha);
}
