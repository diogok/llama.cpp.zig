const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // consider building with mcpu=x86_64_v3 for broader compatibility, due to avx
    const target = b.standardTargetOptions(.{});
    var optimize = b.standardOptimizeOption(.{});
    optimize = .ReleaseFast; //override optimize, not all modes work currently.

    const strip = b.option(bool, "strip", "Strip binary") orelse false;
    const backend = b.option(Backend, "backend", "Choose backend") orelse .cpu;

    const options = Options{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        .strip = strip,
    };
    const llama = buildLlamaCpp(b, options);

    buildRun(b, llama, options);
    buildBench(b, llama, options);
    buildServer(b, llama, options);

    buildDemo(b, llama, options);
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

fn buildLlamaCpp(
    b: *std.Build,
    options: Options,
) *std.Build.Step.Compile {
    // upstream llama.cpp
    const llama_dep = b.dependency("llama_cpp", .{});

    var mod = b.addModule(
        "llama_cpp",
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

    mod.addIncludePath(llama_dep.path("src"));
    mod.addIncludePath(llama_dep.path("include"));

    const src_path = llama_dep.path("src");

    const c_files = listFilesWithExtension(b, src_path, ".c") catch @panic("can't list C files for GGML");
    for (c_files) |file| {
        mod.addCSourceFile(.{
            .file = file,
            .flags = cflags,
        });
    }

    const cpp_files = listFilesWithExtension(b, src_path, ".cpp") catch @panic("can't list C++ files for GGML");
    for (cpp_files) |file| {
        mod.addCSourceFile(.{
            .file = file,
            .flags = cppflags,
        });
    }

    const build_info_file = b.addWriteFile("build-info.cpp", build_info_cpp_src);
    mod.addCSourceFiles(.{
        .root = build_info_file.getDirectory(),
        .files = &.{"build-info.cpp"},
        .flags = cppflags,
    });

    // each model cpp
    var model_files = std.array_list.Managed([]const u8).init(b.allocator);
    defer model_files.deinit();

    const src_shader_path = llama_dep.path("src/models");
    var iterable_dir = std.fs.cwd().openDir(src_shader_path.getPath(b), .{ .iterate = true }) catch @panic("failed to open generated shaders dir");
    defer iterable_dir.close();
    var it = iterable_dir.iterate();
    while (it.next() catch @panic("failed to iterate models dir")) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".cpp")) {
            const cpp = b.dupe(entry.name);
            model_files.append(cpp) catch @panic("failed to add model cpp");
        }
    }
    mod.addCSourceFiles(.{
        .root = llama_dep.path("src/models"),
        .files = model_files.items,
        .flags = cppflags,
    });

    const ggml_dep = b.dependency(
        "ggml",
        .{
            .target = options.target,
            .optimize = options.optimize,
            .backend = options.backend,
        },
    );
    const ggml_lib = ggml_dep.artifact("ggml");
    mod.linkLibrary(ggml_lib);
    mod.lib_paths.appendSlice(b.allocator, ggml_lib.root_module.lib_paths.items) catch unreachable;

    const common_lib = buildCommon(b, ggml_lib, options);
    mod.linkLibrary(common_lib);

    var lib = b.addLibrary(.{
        .name = "llama_cpp",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    lib.installLibraryHeaders(ggml_lib);
    lib.installLibraryHeaders(common_lib);
    lib.installHeadersDirectory(llama_dep.path("include"), "", .{});

    return lib;
}

fn buildCommon(
    b: *std.Build,
    ggml_lib: *std.Build.Step.Compile,
    options: Options,
) *std.Build.Step.Compile {
    const llama_dep = b.dependency("llama_cpp", .{});

    var mod = b.addModule(
        "llama_common",
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
        .windows => {
            mod.linkSystemLibrary("ws2_32", .{});
        },
        else => {},
    }

    mod.addCMacro("NDEBUG", "");
    mod.addCMacro("LLAMA_USE_HTTPLIB", "");

    mod.addIncludePath(llama_dep.path("common"));
    mod.addIncludePath(llama_dep.path("include"));
    mod.addIncludePath(llama_dep.path("vendor"));

    mod.linkLibrary(ggml_lib);
    mod.lib_paths.appendSlice(b.allocator, ggml_lib.root_module.lib_paths.items) catch unreachable;

    const src_path = llama_dep.path("common");
    const cpp_files = listFilesWithExtension(b, src_path, ".cpp") catch @panic("can't list C++ files for GGML");
    for (cpp_files) |file| {
        mod.addCSourceFile(.{
            .file = file,
            .flags = cppflags,
        });
    }

    // jinja cpp files (moved from header-only to separate .cpp files)
    const jinja_path = llama_dep.path("common/jinja");
    const jinja_files = listFilesWithExtension(b, jinja_path, ".cpp") catch @panic("can't list C++ files for jinja");
    for (jinja_files) |file| {
        mod.addCSourceFile(.{
            .file = file,
            .flags = cppflags,
        });
    }

    mod.addCSourceFile(.{
        .file = llama_dep.path("vendor/cpp-httplib/httplib.cpp"),
        .flags = cppflags,
    });

    // LICENSES symbol stub (normally generated by CMake)
    const licenses_file = b.addWriteFile("licenses.cpp",
        \\const char * LICENSES[] = { 0 };
    );
    mod.addCSourceFiles(.{
        .root = licenses_file.getDirectory(),
        .files = &.{"licenses.cpp"},
        .flags = cppflags,
    });

    var lib = b.addLibrary(.{
        .name = "llama_common",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    lib.installHeadersDirectory(llama_dep.path("common"), "", .{});

    return lib;
}

fn buildMTMD(
    b: *std.Build,
    llama: *std.Build.Step.Compile,
    options: Options,
) *std.Build.Step.Compile {
    const llama_dep = b.dependency("llama_cpp", .{});

    var mod = b.addModule(
        "mtmd",
        .{
            .target = options.target,
            .optimize = options.optimize,
            .strip = options.strip,
            .link_libc = true,
            .link_libcpp = true,
        },
    );
    switch (options.target.result.os.tag) {
        .windows => {
            mod.addCMacro("_USE_MATH_DEFINES", "");
        },
        else => {},
    }

    mod.addCMacro("NDEBUG", "");

    mod.addIncludePath(llama_dep.path("common"));
    mod.addIncludePath(llama_dep.path("include"));
    mod.addIncludePath(llama_dep.path("vendor"));
    mod.addIncludePath(llama_dep.path("tools/mtmd"));
    mod.addIncludePath(llama_dep.path("tools/mtmd/models"));

    mod.linkLibrary(llama);
    mod.lib_paths.appendSlice(b.allocator, llama.root_module.lib_paths.items) catch unreachable;

    const src_path = llama_dep.path("tools/mtmd");
    const cpp_files = listFilesWithExtension(b, src_path, ".cpp") catch @panic("can't list C++ files for GGML");
    for (cpp_files) |file| {
        if (std.mem.endsWith(u8, file.getPath(b), "deprecation-warning.cpp") or
            std.mem.endsWith(u8, file.getPath(b), "mtmd-cli.cpp")) continue;
        mod.addCSourceFile(.{
            .file = file,
            .flags = cppflags,
        });
    }

    const src_path2 = llama_dep.path("tools/mtmd/models");
    const cpp_files2 = listFilesWithExtension(b, src_path2, ".cpp") catch @panic("can't list C++ files for GGML");
    for (cpp_files2) |file| {
        mod.addCSourceFile(.{
            .file = file,
            .flags = cppflags,
        });
    }

    var lib = b.addLibrary(.{
        .name = "mtmd",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    lib.installHeadersDirectory(llama_dep.path("tools/mtmd"), "", .{});

    return lib;
}

fn buildBench(
    b: *std.Build,
    llama: *std.Build.Step.Compile,
    options: Options,
) void {
    const name = "llama-bench";

    const mod = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.strip,
        .link_libc = true,
        .link_libcpp = true,
    });

    const llama_dep = b.dependency("llama_cpp", .{});
    mod.addCSourceFiles(.{
        .root = llama_dep.path("tools/llama-bench"),
        .files = &.{"llama-bench.cpp"},
        .flags = cppflags,
    });
    mod.addCMacro("NDEBUG", "");

    mod.addIncludePath(llama_dep.path("vendor"));
    mod.addIncludePath(llama_dep.path("common"));
    mod.addIncludePath(llama_dep.path("include"));
    mod.addIncludePath(llama_dep.path("ggml/include"));

    mod.linkLibrary(llama);
    mod.lib_paths.appendSlice(b.allocator, llama.root_module.lib_paths.items) catch unreachable;
    if (options.backend == .vulkan) linkVulkanSystem(options.target, mod);

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });
    b.installArtifact(exe);
    installWithSuffixes(b, exe, options);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s}", .{name}));
    run_step.dependOn(&run_cmd.step);
}

fn buildRun(
    b: *std.Build,
    llama: *std.Build.Step.Compile,
    options: Options,
) void {
    const name = "llama-run";

    const mod = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.strip,
        .link_libc = true,
        .link_libcpp = true,
    });

    const llama_dep = b.dependency("llama_cpp", .{});
    mod.addCSourceFiles(.{
        .root = llama_dep.path("tools/cli"),
        .files = &.{
            "cli.cpp",
        },
        .flags = cppflags,
    });

    mod.addIncludePath(llama_dep.path("vendor"));
    mod.addIncludePath(llama_dep.path("common"));
    mod.addIncludePath(llama_dep.path("include"));
    mod.addIncludePath(llama_dep.path("ggml/include"));
    mod.addIncludePath(llama_dep.path("tools/server"));
    mod.addIncludePath(llama_dep.path("tools/mtmd"));

    mod.linkLibrary(llama);
    mod.lib_paths.appendSlice(b.allocator, llama.root_module.lib_paths.items) catch unreachable;
    if (options.backend == .vulkan) linkVulkanSystem(options.target, mod);

    // cli.cpp depends on server code (exclude server.cpp which has its own main)
    const srv_path = llama_dep.path("tools/server");
    const server_cpp_files = listFilesWithExtension(b, srv_path, ".cpp") catch @panic("can't list C++ files for server");
    for (server_cpp_files) |file| {
        if (std.mem.endsWith(u8, file.getPath(b), "server.cpp")) continue;
        mod.addCSourceFile(.{
            .file = file,
            .flags = cppflags,
        });
    }

    const mtmd = buildMTMD(b, llama, options);
    mod.linkLibrary(mtmd);

    // use xxd to compile server assets
    const xxd_mod2 = b.addModule(
        "xxd_run",
        .{
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        },
    );
    xxd_mod2.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{
            "xxd.c",
        },
        .flags = &.{},
    });
    const xxd_exe2 = b.addExecutable(.{
        .name = "xxd_run",
        .root_module = xxd_mod2,
    });
    const xxd_run_0b = b.addRunArtifact(xxd_exe2);
    xxd_run_0b.setCwd(llama_dep.path("tools/server/public"));
    xxd_run_0b.addArg("-i");
    xxd_run_0b.addArg("index.html.gz");
    const index2 = xxd_run_0b.addOutputFileArg("index.html.gz.hpp");

    const xxd_run_1b = b.addRunArtifact(xxd_exe2);
    xxd_run_1b.setCwd(llama_dep.path("tools/server/public"));
    xxd_run_1b.addArg("-i");
    xxd_run_1b.addArg("loading.html");
    const loading2 = xxd_run_1b.addOutputFileArg("loading.html.hpp");

    mod.addIncludePath(index2.dirname());
    mod.addIncludePath(loading2.dirname());

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });
    b.installArtifact(exe);
    installWithSuffixes(b, exe, options);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s}", .{name}));
    run_step.dependOn(&run_cmd.step);
}

fn buildServer(
    b: *std.Build,
    llama: *std.Build.Step.Compile,
    options: Options,
) void {
    const name = "llama-server";

    const mod = b.createModule(.{
        .target = options.target,
        .optimize = options.optimize,
        .strip = options.strip,
        .link_libc = true,
        .link_libcpp = true,
    });

    const llama_dep = b.dependency("llama_cpp", .{});

    mod.addIncludePath(llama_dep.path("vendor"));
    mod.addIncludePath(llama_dep.path("common"));
    mod.addIncludePath(llama_dep.path("include"));
    mod.addIncludePath(llama_dep.path("ggml/include"));
    mod.addIncludePath(llama_dep.path("tools/server"));

    const src_path = llama_dep.path("tools/server");
    const cpp_files = listFilesWithExtension(b, src_path, ".cpp") catch @panic("can't list C++ files for GGML");
    for (cpp_files) |file| {
        mod.addCSourceFile(.{
            .file = file,
            .flags = cppflags,
        });
    }

    mod.linkLibrary(llama);
    mod.lib_paths.appendSlice(b.allocator, llama.root_module.lib_paths.items) catch unreachable;
    if (options.backend == .vulkan) linkVulkanSystem(options.target, mod);

    const mtmd = buildMTMD(b, llama, options);
    mod.linkLibrary(mtmd);

    const common = buildCommon(b, llama, options);
    mod.linkLibrary(common);

    // use xxd to compile assets
    const xxd_mod = b.addModule(
        "xxd",
        .{
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        },
    );
    xxd_mod.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{
            "xxd.c",
        },
        .flags = &.{},
    });
    const xxd_exe = b.addExecutable(.{
        .name = "xxd",
        .root_module = xxd_mod,
    });
    const xxd_run_0 = b.addRunArtifact(xxd_exe);
    xxd_run_0.setCwd(llama_dep.path("tools/server/public"));
    xxd_run_0.addArg("-i");
    xxd_run_0.addArg("index.html.gz");
    const index = xxd_run_0.addOutputFileArg("index.html.gz.hpp");

    const xxd_run_1 = b.addRunArtifact(xxd_exe);
    xxd_run_1.setCwd(llama_dep.path("tools/server/public"));
    xxd_run_1.addArg("-i");
    xxd_run_1.addArg("loading.html");
    const loading = xxd_run_1.addOutputFileArg("loading.html.hpp");

    mod.addIncludePath(index.dirname());
    mod.addIncludePath(loading.dirname());

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = mod,
    });
    b.installArtifact(exe);
    installWithSuffixes(b, exe, options);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step(b.fmt("run-{s}", .{name}), b.fmt("Run {s}", .{name}));
    run_step.dependOn(&run_cmd.step);
}

fn buildDemo(
    b: *std.Build,
    llama: *std.Build.Step.Compile,
    options: Options,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/demo.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });

    mod.linkLibrary(llama);

    // workaround until this issue is resolved: https://github.com/ziglang/zig/pull/23936
    mod.lib_paths.appendSlice(b.allocator, llama.root_module.lib_paths.items) catch unreachable;
    if (options.backend == .vulkan) linkVulkanSystem(options.target, mod);

    const exe = b.addExecutable(.{
        .name = "demo",
        .root_module = mod,
    });
    b.installArtifact(exe);
    installWithSuffixes(b, exe, options);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run-demo", "Run demo");
    run_step.dependOn(&run_cmd.step);
}

fn installWithSuffixes(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    options: Options,
) void {
    var ext: []const u8 = "";
    if (options.target.result.os.tag == .windows) {
        ext = ".exe";
    }
    const filename = b.fmt(
        "{s}-{s}-{s}-{s}{s}",
        .{
            exe.name,
            @tagName(options.backend),
            @tagName(options.target.result.cpu.arch),
            @tagName(options.target.result.os.tag),
            ext,
        },
    );
    const install = b.addInstallArtifact(exe, .{ .dest_sub_path = filename });
    b.getInstallStep().dependOn(&install.step);
}

const build_info_cpp_src =
    \\int LLAMA_BUILD_NUMBER = 999999;
    \\char const *LLAMA_COMMIT = "master";
    \\char const *LLAMA_COMPILER = "Zig";
    \\char const *LLAMA_BUILD_TARGET = "any";
;

fn listFilesWithExtension(
    b: *std.Build,
    base_path: std.Build.LazyPath,
    ext: []const u8,
) ![]const std.Build.LazyPath {
    var count: usize = 0;

    var iterable_dir = try std.fs.cwd().openDir(
        base_path.getPath(b),
        .{
            .iterate = true,
        },
    );
    defer iterable_dir.close();
    var it = iterable_dir.iterate();
    while (try it.next()) |entry| {
        if (std.mem.endsWith(
            u8,
            entry.name,
            ext,
        )) {
            count += 1;
        }
    }
    it.reset();

    const paths = try b.allocator.alloc(std.Build.LazyPath, count);

    var i: usize = 0;
    while (try it.next()) |entry| {
        if (std.mem.endsWith(
            u8,
            entry.name,
            ext,
        )) {
            paths[i] = base_path.path(b, entry.name);
            i += 1;
        }
    }

    return paths;
}

fn linkVulkanSystem(
    target: std.Build.ResolvedTarget,
    mod: *std.Build.Module,
) void {
    switch (target.result.os.tag) {
        .linux => mod.linkSystemLibrary("vulkan", .{}),
        .windows => mod.linkSystemLibrary("vulkan-1", .{}),
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
