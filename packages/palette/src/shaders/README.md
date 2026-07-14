# Palette GPU Shader Assets

Palette's SDL_GPU renderer runs on the native backend for each desktop OS.

Required runtime shader formats:

- Vulkan: SPIR-V (`SDL_GPU_SHADERFORMAT_SPIRV`)
- Metal: MSL or metallib (`SDL_GPU_SHADERFORMAT_MSL` or `SDL_GPU_SHADERFORMAT_METALLIB`)
- Windows D3D12: DXIL shader model 6.0 (`SDL_GPU_SHADERFORMAT_DXIL`)

The renderer embeds the checked-in SPIR-V, Metal, and DXIL packages through
`renderer.ShaderSource`. Windows does not require Vulkan.

Run `zig build compile-gpu-shaders` after changing GLSL source. It regenerates:

- `ui.vert.spv`
- `ui.solid.frag.spv`
- `ui.text.frag.spv`
- `ui.image.frag.spv`

Run `python scripts/dev/compile-windows-shaders.py` from the repository root
after changing HLSL source. The script requires Microsoft's pinned
DirectXShaderCompiler `v1.9.2602.24` (`1.9.0.5191`) and regenerates all four
`.dxil` files. Use `--check` in CI to rebuild in a temporary directory and
byte-compare the committed artifacts.

Text commands are rendered with SDL_ttf's GPU text engine. It provides atlas
textures and glyph geometry, while Palette owns the SDL_GPU text pipeline,
sampler binding, vertex/index uploads, clipping, and draw submission.
