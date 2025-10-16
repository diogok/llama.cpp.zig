const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = optimize;

    const strip = b.option(bool, "strip", "Strip binary") orelse false;
    const backend = b.option(Backend, "backend", "Choose backend") orelse .cpu;

    const options = Options{
        .target = target,
        .optimize = .ReleaseFast, // others are not working
        .backend = backend,
        .strip = strip,
    };

    const vulkan_shaders_files = genVulkanShaders(b);
    const run_step = b.step("generate-vulkan-shaders", "Generate vulkan shaders");
    run_step.dependOn(&vulkan_shaders_files.step);

    buildGGML(b, options);
}

const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    backend: Backend,
};

const Backend = enum(u8) {
    cpu,
    vulkan,
};

fn buildGGML(
    b: *std.Build,
    options: Options,
) void {
    const dep = b.dependency("ggml", .{});

    var mod = b.addModule(
        "ggml",
        .{
            .target = options.target,
            .optimize = options.optimize,
            .strip = options.strip,
            .link_libc = true,
            .link_libcpp = true,
        },
    );

    switch (options.target.result.os.tag) {
        .linux => {
            mod.addCMacro("_GNU_SOURCE", "");
        },
        else => {},
    }
    mod.addCMacro("GGML_USE_CPU", "1");
    mod.linkLibrary(buildGGMLCpu(b, options));

    switch (options.backend) {
        .vulkan => {
            mod.addCMacro("GGML_USE_VULKAN", "1");
            linkVulkan(b, options.target, mod);
            const vulkan_lib = buildGGMLVulkan(b, options);
            mod.linkLibrary(vulkan_lib);
            mod.lib_paths.appendSlice(b.allocator, vulkan_lib.root_module.lib_paths.items) catch unreachable;
        },
        else => {},
    }

    mod.addCMacro("NDEBUG", "");
    mod.addCMacro("GGML_VERSION", "0");
    mod.addCMacro("GGML_COMMIT", "\"unknown\"");

    mod.addIncludePath(dep.path(src_prefix ++ "src"));
    mod.addIncludePath(dep.path(src_prefix ++ "include"));

    mod.addCSourceFiles(.{
        .root = dep.path(src_prefix ++ "src"),
        .files = ggml_src_c,
        .flags = cflags,
    });

    mod.addCSourceFiles(.{
        .root = dep.path(src_prefix ++ "src"),
        .files = ggml_src_cpp,
        .flags = cppflags,
    });

    var lib = b.addLibrary(.{
        .name = "ggml",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    lib.installHeadersDirectory(dep.path(src_prefix ++ "include"), "", .{});
    lib.installHeadersDirectory(dep.path(src_prefix ++ "src"), "", .{});
}

fn buildGGMLCpu(
    b: *std.Build,
    options: Options,
) *std.Build.Step.Compile {
    const dep = b.dependency("ggml", .{});

    var mod = b.addModule(
        "ggml_cpu",
        .{
            .target = options.target,
            .optimize = options.optimize,
            .strip = options.strip,
            .link_libc = true,
            .link_libcpp = true,
        },
    );

    switch (options.target.result.os.tag) {
        .linux => {
            mod.addCMacro("_GNU_SOURCE", "");
        },
        else => {},
    }

    mod.addCMacro("NDEBUG", "");

    mod.addIncludePath(dep.path(src_prefix ++ "src"));
    mod.addIncludePath(dep.path(src_prefix ++ "include"));
    mod.addIncludePath(dep.path(src_prefix ++ "src/ggml-cpu"));
    mod.addIncludePath(dep.path(src_prefix ++ "src/ggml-cpu/amx"));

    mod.addCSourceFiles(.{
        .root = dep.path(src_prefix ++ "src/ggml-cpu"),
        .files = ggml_cpu_src_c,
        .flags = cflags,
    });

    mod.addCSourceFiles(.{
        .root = dep.path(src_prefix ++ "src/ggml-cpu"),
        .files = ggml_cpu_src_cpp,
        .flags = cppflags,
    });

    const cpu = options.target.result.cpu;
    switch (cpu.arch) {
        .x86_64 => {
            mod.addCSourceFiles(.{
                .root = dep.path(src_prefix ++ "src/ggml-cpu/arch/x86"),
                .files = &[_][]const u8{"quants.c"},
                .flags = cflags,
            });
            mod.addCSourceFiles(.{
                .root = dep.path(src_prefix ++ "src/ggml-cpu/arch/x86"),
                .files = &[_][]const u8{ "cpu-feats.cpp", "repack.cpp" },
                .flags = cppflags,
            });
            if (cpu.has(.x86, .sse4_2)) {
                mod.addCMacro("GGML_SSE42", "");
            }
            if (cpu.has(.x86, .avx)) {
                mod.addCMacro("GGML_AVX", "");
            }
            if (cpu.has(.x86, .avx2)) {
                mod.addCMacro("GGML_AVX2", "");
            }
            if (cpu.has(.x86, .bmi2)) {
                mod.addCMacro("GGML_BMI2", "");
            }
            if (cpu.has(.x86, .avxvnni)) {
                mod.addCMacro("GGML_AVX_VNNI", "");
            }
            if (cpu.has(.x86, .fma)) {
                mod.addCMacro("GGML_FMA", "");
            }
            if (cpu.has(.x86, .f16c)) {
                mod.addCMacro("GGML_F16C", "");
            }
            if (cpu.hasAll(.x86, &[_]std.Target.x86.Feature{ .avx512f, .avx512cd, .avx512er, .avx512pf })) {
                mod.addCMacro("GGML_AVX512", "");
            }
            if (cpu.has(.x86, .avx512vbmi)) {
                mod.addCMacro("GGML_AVX512_VBMI", "");
            }
            if (cpu.has(.x86, .avx512vnni)) {
                mod.addCMacro("GGML_AVX512_VNNI", "");
            }
            if (cpu.has(.x86, .avx512bf16)) {
                mod.addCMacro("GGML_AVX512_BF16", "");
            }
            if (cpu.has(.x86, .amx_tile)) {
                mod.addCMacro("GGML_AMX_TILE", "");
            }
            if (cpu.has(.x86, .amx_int8)) {
                mod.addCMacro("GGML_AMX_INT8", "");
            }
            if (cpu.has(.x86, .amx_bf16)) {
                mod.addCMacro("GGML_AMX_BF16", "");
            }
        },
        .aarch64 => {
            mod.addCSourceFiles(.{
                .root = dep.path(src_prefix ++ "src/ggml-cpu/arch/arm"),
                .files = &[_][]const u8{"quants.c"},
                .flags = cflags,
            });
            mod.addCSourceFiles(.{
                .root = dep.path(src_prefix ++ "src/ggml-cpu/arch/arm"),
                .files = &[_][]const u8{ "cpu-feats.cpp", "repack.cpp" },
                .flags = cppflags,
            });
            if (cpu.has(.arm, .v8_2a)) {
                mod.addCMacro("GGML_USE_DOTPROD", "");
                mod.addCMacro("GGML_USE_FP16_VECTOR_ARITHMETIC", "");
                mod.addCMacro("GGML_USE_SVE", "");
            }
            if (cpu.has(.arm, .v8_6a)) {
                mod.addCMacro("GGML_USE_MATMUL_INT8", "");
                mod.addCMacro("GGML_USE_SVE2", "");
            }
            if (cpu.has(.arm, .v9_2a)) {
                mod.addCMacro("GGML_USE_SME", "");
            }
        },
        else => {},
    }

    const lib = b.addLibrary(.{
        .name = "ggml_cpu",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    return lib;
}

fn buildGGMLVulkan(
    b: *std.Build,
    options: Options,
) *std.Build.Step.Compile {
    const dep = b.dependency("ggml", .{});
    const vk_hpp = b.dependency("vulkan_hpp", .{});
    const vk_headers = b.dependency("vulkan_headers", .{});

    var mod = b.addModule(
        "ggml_vulkan",
        .{
            .link_libc = true,
            .link_libcpp = true,
            .target = options.target,
            .optimize = options.optimize,
            .strip = options.strip,
        },
    );
    mod.addCMacro("NDEBUG", "");

    mod.addCMacro("VK_NV_cooperative_matrix", "");
    mod.addCMacro("VK_NV_cooperative_matrix2", "");
    mod.addCMacro("GGML_VULKAN_INTEGER_DOT_GLSLC_SUPPORT", "");
    mod.addCMacro("GGML_VULKAN_BFLOAT16_GLSLC_SUPPORT", "");
    mod.addCMacro("GGML_VULKAN_COOPMAT_GLSLC_SUPPORT", "");
    mod.addCMacro("GGML_VULKAN_COOPMAT2_GLSLC_SUPPORT", "");
    //mod.addCMacro("GGML_VULKAN_MEMORY_DEBUG", "");
    //mod.addCMacro("GGML_VULKAN_DEBUG", "");

    mod.addIncludePath(dep.path(src_prefix ++ "src"));
    mod.addIncludePath(dep.path(src_prefix ++ "include"));

    mod.addIncludePath(vk_hpp.path("vulkan"));
    mod.addIncludePath(vk_headers.path("include"));

    mod.addIncludePath(b.path("src/vulkan-shaders"));

    mod.addCSourceFiles(.{
        .root = dep.path(src_prefix ++ "src/ggml-vulkan"),
        .files = &.{
            "ggml-vulkan.cpp",
        },
        .flags = cppflags,
    });

    linkVulkan(b, options.target, mod);

    const vk_shaders = buildVulkanShaders(b, options);
    mod.linkLibrary(vk_shaders);

    const lib = b.addLibrary(.{
        .name = "ggml_vulkan",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    return lib;
}

fn buildVulkanShaders(
    b: *std.Build,
    options: Options,
) *std.Build.Step.Compile {
    const ggml_dep = b.dependency("ggml", .{});

    var mod = b.addModule(
        "vulkan_shaders",
        .{
            .link_libc = true,
            .link_libcpp = true,
            .target = options.target,
            .optimize = options.optimize,
            .strip = options.strip,
        },
    );
    mod.addCMacro("GGML_VULKAN_COOPMAT_GLSLC_SUPPORT", "");
    mod.addCMacro("GGML_VULKAN_COOPMAT2_GLSLC_SUPPORT", "");
    mod.addCMacro("GGML_VULKAN_INTEGER_DOT_GLSLC_SUPPORT", "");
    mod.addCMacro("GGML_VULKAN_BFLOAT16_GLSLC_SUPPORT", "");

    const vk_shaders = genVulkanShaders(b);
    const vk_shaders_path = "src/vulkan-shaders";
    const gen_shader_path = b.path(vk_shaders_path);
    mod.addIncludePath(gen_shader_path);

    var shader_files = std.array_list.Managed([]const u8).init(b.allocator);
    defer shader_files.deinit();

    // add each shader
    const src_shader_path = ggml_dep.path(src_prefix ++ "src/ggml-vulkan/vulkan-shaders/");
    var iterable_dir = std.fs.cwd().openDir(src_shader_path.getPath(b), .{ .iterate = true }) catch @panic("failed to open generated shaders dir");
    defer iterable_dir.close();
    var it = iterable_dir.iterate();
    while (it.next() catch @panic("failed to iterate generated shaders dir")) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".comp")) {
            const cpp = b.fmt("{s}.cpp", .{entry.name});
            shader_files.append(cpp) catch @panic("failed to add generated shader cpp");
        }
    }

    mod.addCSourceFiles(.{
        .root = gen_shader_path,
        .files = shader_files.items,
        .flags = cppflags,
    });

    const lib = b.addLibrary(.{
        .name = "vulkan_shaders",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);
    lib.step.dependOn(&vk_shaders.step);

    lib.installHeadersDirectory(gen_shader_path, "", .{});

    return lib;
}

fn genVulkanShaders(
    b: *std.Build,
) *std.Build.Step.UpdateSourceFiles {
    const shaderc = b.dependency("shaderc", .{ .optimize = .ReleaseFast });
    const glslc = shaderc.artifact("glslc");

    const dep = b.dependency("ggml", .{});

    const vulkan_shaders_gen_exe = buildVulkanShadersGen(b);

    // copy generated files
    const vulkan_shaders_files = b.addUpdateSourceFiles();

    // generate header
    const vk_hpp_cmd = b.addRunArtifact(vulkan_shaders_gen_exe);
    vk_hpp_cmd.addArg("--glslc");
    vk_hpp_cmd.addFileArg(glslc.getEmittedBin());
    vk_hpp_cmd.addArg("--output-dir");
    _ = vk_hpp_cmd.addOutputDirectoryArg("vulkan-shaders");
    vk_hpp_cmd.addArg("--target-hpp");
    const vk_hpp = vk_hpp_cmd.addOutputFileArg("ggml-vulkan-shaders.hpp");

    const hpp_path = "src/vulkan-shaders/ggml-vulkan-shaders.hpp";
    vulkan_shaders_files.addCopyFileToSource(vk_hpp, hpp_path);

    const src_shader_path = dep.path(src_prefix ++ "src/ggml-vulkan/vulkan-shaders/");
    var iterable_dir = std.fs.cwd().openDir(src_shader_path.getPath(b), .{ .iterate = true }) catch @panic("failed to open generated shaders dir");
    defer iterable_dir.close();
    var it = iterable_dir.iterate();
    while (it.next() catch @panic("failed to iterate generated shaders dir")) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".comp")) {
            const vk_cpp_cmd = b.addRunArtifact(vulkan_shaders_gen_exe);
            vk_cpp_cmd.addArg("--glslc");
            vk_cpp_cmd.addFileArg(glslc.getEmittedBin());
            vk_cpp_cmd.addArg("--source");
            vk_cpp_cmd.addFileArg(dep.path(b.fmt(src_prefix ++ "src/ggml-vulkan/vulkan-shaders/{s}", .{entry.name})));
            vk_cpp_cmd.addArg("--output-dir");
            _ = vk_cpp_cmd.addOutputDirectoryArg("vulkan-shaders");
            vk_cpp_cmd.addArg("--target-hpp");
            vk_cpp_cmd.addFileArg(vk_hpp);
            vk_cpp_cmd.addArg("--target-cpp");
            const cpp_path = b.fmt("src/vulkan-shaders/{s}.cpp", .{entry.name});
            const vk_cpp = vk_cpp_cmd.addOutputFileArg(cpp_path);
            vulkan_shaders_files.addCopyFileToSource(vk_cpp, cpp_path);
        }
    }

    return vulkan_shaders_files;
}

fn buildVulkanShadersGen(b: *std.Build) *std.Build.Step.Compile {
    const dep = b.dependency("ggml", .{});

    const mod = b.createModule(.{
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .link_libcpp = true,
    });

    mod.addCSourceFiles(.{
        .root = dep.path(src_prefix ++ "src/ggml-vulkan/vulkan-shaders/"),
        .files = &.{
            "vulkan-shaders-gen.cpp",
        },
        .flags = cppflags,
    });

    mod.addCMacro("GGML_VULKAN_COOPMAT_GLSLC_SUPPORT", "");
    mod.addCMacro("GGML_VULKAN_COOPMAT2_GLSLC_SUPPORT", "");
    mod.addCMacro("GGML_VULKAN_INTEGER_DOT_GLSLC_SUPPORT", "");
    mod.addCMacro("GGML_VULKAN_BFLOAT16_GLSLC_SUPPORT", "");
    mod.addCMacro("VK_NV_cooperative_matrix", "");
    mod.addCMacro("VK_NV_cooperative_matrix2", "");
    mod.addCMacro("COOPMAT", "");
    mod.addCMacro("COOPMAT2", "");

    const vulkan_shaders_gen_exe = b.addExecutable(.{
        .name = "vulkan-shaders-gen",
        .root_module = mod,
    });

    return vulkan_shaders_gen_exe;
}

pub fn linkVulkan(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    mod: *std.Build.Module,
) void {
    const sdk_name = b.fmt("vulkan_sdk_{s}_{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) });
    _ = std.mem.replaceScalar(u8, sdk_name, '-', '_');

    var vulkan_sdk_dep = b.lazyDependency(sdk_name, .{});
    if (vulkan_sdk_dep == null) {
        return;
    }

    switch (target.result.os.tag) {
        .linux => {
            const arch = @tagName(target.result.cpu.arch);
            mod.addLibraryPath(vulkan_sdk_dep.?.path(b.fmt("{s}/lib", .{arch})));
            mod.linkSystemLibrary("vulkan", .{});
        },
        .windows => {
            switch (target.result.cpu.arch) {
                .x86_64 => {
                    mod.addLibraryPath(vulkan_sdk_dep.?.path("x64"));
                    mod.linkSystemLibrary("vulkan-1", .{});
                },
                .aarch64 => {
                    mod.addLibraryPath(vulkan_sdk_dep.?.path(""));
                    mod.linkSystemLibrary("vulkan-1", .{});
                },
                else => {},
            }
        },
        else => {},
    }
}

const cflags: []const []const u8 = &.{
    "-fPIC",
    "-std=c11",
    "-O3",
};

const cppflags: []const []const u8 = &.{
    "-fPIC",
    "-std=c++17",
    "-O3",
};

const ggml_src_c: []const []const u8 = &.{
    "ggml.c",
    "ggml-alloc.c",
    "ggml-quants.c",
};

const ggml_src_cpp: []const []const u8 = &.{
    "ggml.cpp",
    "ggml-backend.cpp",
    "ggml-opt.cpp",
    "ggml-threading.cpp",
    "gguf.cpp",

    "ggml-backend-reg.cpp",
};

const ggml_cpu_src_c: []const []const u8 = &.{
    "ggml-cpu.c",
    "quants.c",
};

const ggml_cpu_src_cpp: []const []const u8 = &.{
    "ggml-cpu.cpp",
    "repack.cpp",
    "hbm.cpp",
    "traits.cpp",
    "amx/amx.cpp",
    "amx/mmq.cpp",
    "binary-ops.cpp",
    "unary-ops.cpp",
    "vec.cpp",
    "ops.cpp",
};

const src_prefix = "ggml/";
