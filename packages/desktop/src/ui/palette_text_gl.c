#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

#include <GL/gl.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct PaletteTextVertex {
    float x;
    float y;
    float u;
    float v;
    float r;
    float g;
    float b;
    float a;
} PaletteTextVertex;

typedef struct PaletteTextAtlas {
    float size;
    float ascent;
    float line_gap;
    GLuint texture;
    stbtt_bakedchar chars[96];
    int ready;
} PaletteTextAtlas;

static PaletteTextAtlas g_atlases[8];
static GLuint g_program;
static GLuint g_vao;
static GLuint g_vbo;
static GLint g_viewport_uniform = -1;
static GLint g_texture_uniform = -1;
static int g_gl_ready;

static GLuint compile_shader(GLenum kind, const char *source) {
    GLuint shader = glCreateShader(kind);
    glShaderSource(shader, 1, &source, 0);
    glCompileShader(shader);
    return shader;
}

static void ensure_gl(void) {
    if (g_gl_ready) return;

    const char *vertex_source =
        "#version 330 core\n"
        "layout (location = 0) in vec2 a_pos;\n"
        "layout (location = 1) in vec2 a_uv;\n"
        "layout (location = 2) in vec4 a_color;\n"
        "uniform vec2 u_viewport;\n"
        "out vec2 v_uv;\n"
        "out vec4 v_color;\n"
        "void main() {\n"
        "  vec2 ndc = vec2((a_pos.x / u_viewport.x) * 2.0 - 1.0, 1.0 - (a_pos.y / u_viewport.y) * 2.0);\n"
        "  gl_Position = vec4(ndc, 0.0, 1.0);\n"
        "  v_uv = a_uv;\n"
        "  v_color = a_color;\n"
        "}\n";
    const char *fragment_source =
        "#version 330 core\n"
        "in vec2 v_uv;\n"
        "in vec4 v_color;\n"
        "uniform sampler2D u_texture;\n"
        "out vec4 color;\n"
        "void main() {\n"
        "  float alpha = texture(u_texture, v_uv).r;\n"
        "  color = vec4(v_color.rgb, v_color.a * alpha);\n"
        "}\n";

    GLuint vs = compile_shader(GL_VERTEX_SHADER, vertex_source);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fragment_source);
    g_program = glCreateProgram();
    glAttachShader(g_program, vs);
    glAttachShader(g_program, fs);
    glLinkProgram(g_program);
    glDeleteShader(vs);
    glDeleteShader(fs);
    g_viewport_uniform = glGetUniformLocation(g_program, "u_viewport");
    g_texture_uniform = glGetUniformLocation(g_program, "u_texture");
    glGenVertexArrays(1, &g_vao);
    glGenBuffers(1, &g_vbo);
    g_gl_ready = 1;
}

static PaletteTextAtlas *atlas_for_size(const unsigned char *font_data, int font_len, float size) {
    (void)font_len;
    float bucket = roundf(size);
    for (int i = 0; i < 8; i += 1) {
        if (g_atlases[i].ready && fabsf(g_atlases[i].size - bucket) < 0.1f) return &g_atlases[i];
    }
    PaletteTextAtlas *atlas = 0;
    for (int i = 0; i < 8; i += 1) {
        if (!g_atlases[i].ready) {
            atlas = &g_atlases[i];
            break;
        }
    }
    if (!atlas) atlas = &g_atlases[0];
    if (atlas->texture) glDeleteTextures(1, &atlas->texture);

    const int atlas_w = 1024;
    const int atlas_h = 1024;
    unsigned char *bitmap = (unsigned char *)calloc((size_t)atlas_w * (size_t)atlas_h, 1);
    if (!bitmap) return 0;
    int bake = stbtt_BakeFontBitmap(font_data, 0, bucket, bitmap, atlas_w, atlas_h, 32, 96, atlas->chars);
    if (bake == 0) {
        free(bitmap);
        atlas->ready = 0;
        return 0;
    }

    stbtt_fontinfo info;
    int ascent = 0;
    int descent = 0;
    int line_gap = 0;
    if (stbtt_InitFont(&info, font_data, stbtt_GetFontOffsetForIndex(font_data, 0))) {
        float scale = stbtt_ScaleForPixelHeight(&info, bucket);
        stbtt_GetFontVMetrics(&info, &ascent, &descent, &line_gap);
        atlas->ascent = (float)ascent * scale;
        atlas->line_gap = (float)(ascent - descent + line_gap) * scale;
    } else {
        atlas->ascent = bucket * 0.82f;
        atlas->line_gap = bucket * 1.25f;
    }

    glGenTextures(1, &atlas->texture);
    glBindTexture(GL_TEXTURE_2D, atlas->texture);
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R8, atlas_w, atlas_h, 0, GL_RED, GL_UNSIGNED_BYTE, bitmap);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    free(bitmap);

    atlas->size = bucket;
    atlas->ready = 1;
    return atlas;
}

static stbtt_fontinfo g_measure_font;
static int g_measure_font_ready;

static void ensure_measure_font(const unsigned char *font_data) {
    if (g_measure_font_ready) return;
    if (!stbtt_InitFont(&g_measure_font, font_data, stbtt_GetFontOffsetForIndex(font_data, 0))) return;
    g_measure_font_ready = 1;
}

/// Horizontal width for `text` using the same ASCII subset and scale as `palette_text_gl_draw`,
/// but via `stbtt_GetCodepointHMetrics` so chunk layout matches variable glyph advances (no GL calls).
float palette_text_gl_measure_line_width(
    const unsigned char *font_data,
    int font_len,
    const char *text,
    int text_len,
    float font_size
) {
    (void)font_len;
    if (!font_data || !text || text_len <= 0 || font_size <= 0.0f) return 0.0f;
    ensure_measure_font(font_data);
    if (!g_measure_font_ready) return 0.0f;

    const float bucket = roundf(font_size);
    const float scale = stbtt_ScaleForPixelHeight(&g_measure_font, bucket);

    float line_w = 0.0f;
    float max_w = 0.0f;
    for (int i = 0; i < text_len; i += 1) {
        unsigned char ch = (unsigned char)text[i];
        if (ch == '\n') {
            if (line_w > max_w) max_w = line_w;
            line_w = 0.0f;
            continue;
        }
        if (ch < 32 || ch > 126) continue;
        int advance = 0;
        int lsb = 0;
        stbtt_GetCodepointHMetrics(&g_measure_font, (int)ch, &advance, &lsb);
        line_w += (float)advance * scale;
    }
    if (line_w > max_w) max_w = line_w;
    return max_w;
}

/// Horizontal advance for a single Unicode codepoint using the same font scale as
/// `palette_text_gl_draw` / `palette_text_gl_measure_line_width`. Characters outside
/// the baked ASCII range (32–126) return 0 width to match the draw loop, which skips them.
float palette_text_gl_measure_codepoint_width(
    const unsigned char *font_data,
    int font_len,
    int codepoint,
    float font_size
) {
    (void)font_len;
    if (!font_data || font_size <= 0.0f) return 0.0f;
    ensure_measure_font(font_data);
    if (!g_measure_font_ready) return 0.55f * font_size;

    if (codepoint < 32 || codepoint > 126) return 0.0f;

    const float bucket = roundf(font_size);
    const float scale = stbtt_ScaleForPixelHeight(&g_measure_font, bucket);
    int advance = 0;
    int lsb = 0;
    stbtt_GetCodepointHMetrics(&g_measure_font, codepoint, &advance, &lsb);
    return (float)advance * scale;
}

void palette_text_gl_draw(
    const unsigned char *font_data,
    int font_len,
    const char *text,
    int text_len,
    float x,
    float y,
    float font_size,
    float r,
    float g,
    float b,
    float a,
    float viewport_w,
    float viewport_h
) {
    if (!font_data || font_len <= 0 || !text || text_len <= 0 || a <= 0.0f) return;
    ensure_gl();
    PaletteTextAtlas *atlas = atlas_for_size(font_data, font_len, font_size);
    if (!atlas || !atlas->ready) return;

    int max_vertices = text_len * 6;
    PaletteTextVertex *vertices = (PaletteTextVertex *)malloc(sizeof(PaletteTextVertex) * (size_t)max_vertices);
    if (!vertices) return;

    float pen_x = x;
    float pen_y = y + atlas->ascent;
    int count = 0;
    for (int i = 0; i < text_len; i += 1) {
        unsigned char ch = (unsigned char)text[i];
        if (ch == '\n') {
            pen_x = x;
            pen_y += atlas->line_gap;
            continue;
        }
        if (ch < 32 || ch > 126) continue;
        stbtt_aligned_quad q;
        stbtt_GetBakedQuad(atlas->chars, 1024, 1024, ch - 32, &pen_x, &pen_y, &q, 1);
        PaletteTextVertex v0 = { q.x0, q.y0, q.s0, q.t0, r, g, b, a };
        PaletteTextVertex v1 = { q.x1, q.y0, q.s1, q.t0, r, g, b, a };
        PaletteTextVertex v2 = { q.x1, q.y1, q.s1, q.t1, r, g, b, a };
        PaletteTextVertex v3 = { q.x0, q.y1, q.s0, q.t1, r, g, b, a };
        vertices[count++] = v0;
        vertices[count++] = v1;
        vertices[count++] = v2;
        vertices[count++] = v0;
        vertices[count++] = v2;
        vertices[count++] = v3;
    }

    if (count > 0) {
        glEnable(GL_BLEND);
        glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
        glUseProgram(g_program);
        glUniform2f(g_viewport_uniform, viewport_w, viewport_h);
        glUniform1i(g_texture_uniform, 0);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, atlas->texture);
        glBindVertexArray(g_vao);
        glBindBuffer(GL_ARRAY_BUFFER, g_vbo);
        glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(sizeof(PaletteTextVertex) * (size_t)count), vertices, GL_STREAM_DRAW);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, sizeof(PaletteTextVertex), (void *)0);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, sizeof(PaletteTextVertex), (void *)(sizeof(float) * 2));
        glEnableVertexAttribArray(2);
        glVertexAttribPointer(2, 4, GL_FLOAT, GL_FALSE, sizeof(PaletteTextVertex), (void *)(sizeof(float) * 4));
        glDrawArrays(GL_TRIANGLES, 0, count);
    }
    free(vertices);
}
