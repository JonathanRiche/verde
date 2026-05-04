# Powder

Powder is Verde's retained UI component package. It uses Zig, SDL3, SDL3_ttf,
and SDL_GPU.

## Setup

Run all commands in this directory:

```bash
cd packages/powder
```

### macOS

Install Zig plus SDL dependencies with Homebrew:

```bash
brew install zig sdl3 sdl3_ttf pkg-config shaderc
```

`pkg-config` is required because the Powder build links Homebrew's SDL
libraries as normal Unix libraries, not as `.framework` bundles. It tells Zig
where SDL headers and libraries are installed.

Verify discovery before building:

```bash
pkg-config --libs --cflags sdl3 sdl3-ttf
```

That command should print include and library flags. If it prints an error,
check that Homebrew is on your shell path and that `pkg-config` can see
Homebrew's `.pc` files.

### Linux

Install Zig, pkg-config, SDL3, SDL3_ttf, and shaderc from your distro packages.
Package names vary, but the required pkg-config modules are:

```bash
pkg-config --libs --cflags sdl3 sdl3-ttf
```

The shader compiler command used by the build is:

```bash
glslc --version
```

## Build And Test

```bash
zig build test
zig build examples
zig build test-gpu-backends
```

Run the visual labs:

```bash
zig build run-text-area-lab
zig build run-component-lab
```

If shader source changes, regenerate the Vulkan SPIR-V assets:

```bash
zig build compile-gpu-shaders
```

## Troubleshooting

If macOS reports `unable to find framework 'SDL3'`, update to a build that uses
pkg-config for SDL, then install:

```bash
brew install sdl3 sdl3_ttf pkg-config
```

If `pkg-config --libs --cflags sdl3 sdl3-ttf` fails on Apple Silicon, make sure
Homebrew's path is active:

```bash
eval "$(/opt/homebrew/bin/brew shellenv)"
```

On Intel macOS, Homebrew is usually under `/usr/local` instead.
