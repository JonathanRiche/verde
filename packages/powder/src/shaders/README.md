# Powder GPU Shader Assets

Powder's SDL_GPU renderer is intended to run on Vulkan and Metal.

Required runtime shader formats:

- Vulkan: SPIR-V (`SDL_GPU_SHADERFORMAT_SPIRV`)
- Metal: MSL or metallib (`SDL_GPU_SHADERFORMAT_MSL` or `SDL_GPU_SHADERFORMAT_METALLIB`)

The checked-in HLSL files are source material only. They are not accepted
directly by SDL_GPU's Vulkan or Metal backends. Build or release packaging must
provide compiled shader code and pass it through `renderer.ShaderPackage`.

Text commands also require a GPU atlas path. The SDL lab presenter can draw
text with SDL_ttf for local inspection, but the production SDL_GPU renderer
reports `GpuTextAtlasNotConfigured` for text batches until an atlas texture and
sampler binding are provided.
