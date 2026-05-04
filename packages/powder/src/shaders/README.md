# Powder GPU Shader Assets

Powder's SDL_GPU renderer is intended to run on Vulkan and Metal.

Required runtime shader formats:

- Vulkan: SPIR-V (`SDL_GPU_SHADERFORMAT_SPIRV`)
- Metal: MSL or metallib (`SDL_GPU_SHADERFORMAT_MSL` or `SDL_GPU_SHADERFORMAT_METALLIB`)

The checked-in HLSL files are source material only. The renderer uses the
checked-in Vulkan SPIR-V files and Metal MSL files through
`renderer.ShaderSource`.

Run `zig build compile-gpu-shaders` after changing GLSL source. It regenerates:

- `ui.vert.spv`
- `ui.solid.frag.spv`
- `ui.text.frag.spv`

Text commands are rendered with SDL_ttf's GPU text engine. It provides atlas
textures and glyph geometry, while Powder owns the SDL_GPU text pipeline,
sampler binding, vertex/index uploads, clipping, and draw submission.
