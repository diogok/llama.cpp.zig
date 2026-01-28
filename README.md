# llama.cpp.zig

A `build.zig` for [llama.cpp](https://github.com/ggml-org/llama.cpp), with Vulkan and Metal.

You can use llama.cpp from Zig projects.

You can also cross-compile llama.cpp to different targets.

## Support

Supported targets are:

- Linux x86_64
- Linux aarch64
- Windows x86_64
- Windows aarch64
- macOS aarch64 (Apple Silicon)

Supported backends are:

- CPU
- Vulkan
- Metal (macOS only)

Other targets and backends can be added with time and test devices.

### Test devices

- Random x86_64 running linux: All good.
- Random x86_64 running windows: All good.
- Raspberry Pi 5 (aarch64 linux): CPU works, Vulkan compiles but don't due to some lack of memory.
- Surface pro X SQ2 (aarch64 windows): CPU works, vulkan compiles but don't run due to some missing feature.
- Termux (aarch64 android/linux): CPU works, vulkan compiles but don't run.
- M4 Pro (aarch64 macOS): All good.

## How to build

All you need is Zig installed. All dependencies are pulled and compiled.

You can compile with:

```sh
zig build install
```

You can choose the backend used:

```sh
zig build install -Dbackend=vulkan
zig build install -Dbackend=cpu #default
zig build install -Dbackend=metal
```

And choose a target architecture and OS:

```sh
zig build install -Dtarget=x86_64-linux
```

First compilation can take several minutes on some plataforms.

## Use in Zig

Add as a dependency on your project:

```sh
zig fetch --save git+https://github.com/diogok/llama.cpp.zig
```

Then build the library on your `buid.zig` like:

```zig
const llama_cpp_dep = b.dependency("llama_cpp_zig", .{
    .target = target,
    .optimize = optimize,
    .backend = backend, // like `.vulkan` or `.cpu`
});
const llama_cpp_lib = llama_cpp_dep.artifact("llama_cpp");
you_module.linkLibrary(llama_cpp_lib);
```

Refer to [src/demo.zig] for an usage example.

### Metal Backend (macOS)

Metal requires the Metal Toolchain to compile shaders at build time:

```sh
xcodebuild -downloadComponent MetalToolchain
```
When building with Metal, the output includes a `default.metallib` file that must be distributed alongside your binaries:

```
zig-out/bin/
├── llama-run
├── llama-server
└── default.metallib   # required for Metal to work
```

## Licenses

MIT
