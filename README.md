# llama.cpp.zig

A `build.zig` for [llama.cpp](https://github.com/ggml-org/llama.cpp), with Vulkan.

You can use llama.cpp from Zig projects.

You can also cross-compile llama.cpp to different targets.

## Support

Supported targets are:

- Linux x86_64
- Linux aarch64
- Windows x86_64
- Windows aarch64

Supported backends are:

- CPU
- Vulkan

Other targets and backends can be added with time and infrastructure.

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

## Licenses

MIT
