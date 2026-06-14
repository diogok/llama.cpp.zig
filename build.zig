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
    const mtmd = buildMTMD(b, llama, options);

    buildRun(b, llama, mtmd, options);
    buildBench(b, llama, options);
    buildServer(b, llama, mtmd, options);

    const c_mod = buildLlamaTranslateC(b, options);
    buildDemo(b, llama, c_mod, options);
    buildTest(b, llama, c_mod, options);
}

fn buildLlamaTranslateC(
    b: *std.Build,
    options: Options,
) *std.Build.Module {
    const llama_dep = b.dependency("llama_cpp", .{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = llama_dep.path("include/llama.h"),
        .target = options.target,
        .optimize = options.optimize,
    });
    translate_c.addIncludePath(llama_dep.path("include"));
    translate_c.addIncludePath(llama_dep.path("ggml/include"));

    const mod = translate_c.createModule();
    // Exposed publicly so external consumers can do
    // `llama_cpp_dep.module("c")` and import llama.h bindings directly,
    // matching how `src/demo.zig` consumes them internally.
    b.modules.put(b.allocator, "c", mod) catch @panic("OOM");
    return mod;
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
    metal,
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

    const build_info_file = b.addWriteFile("build-info.cpp", buildInfoCppSrc(b, options));
    mod.addCSourceFiles(.{
        .root = build_info_file.getDirectory(),
        .files = &.{"build-info.cpp"},
        .flags = cppflags,
    });

    // each model cpp
    var model_files: std.ArrayList([]const u8) = .empty;
    defer model_files.deinit(b.allocator);

    const io = b.graph.io;
    const src_shader_path = llama_dep.path("src/models");
    var iterable_dir = std.Io.Dir.cwd().openDir(io, src_shader_path.getPath(b), .{ .iterate = true }) catch @panic("failed to open generated shaders dir");
    defer iterable_dir.close(io);
    var it = iterable_dir.iterate();
    while (it.next(io) catch @panic("failed to iterate models dir")) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".cpp")) {
            const cpp = b.dupe(entry.name);
            model_files.append(b.allocator, cpp) catch @panic("failed to add model cpp");
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

    // Install Metal shader library if using Metal backend
    if (options.backend == .metal) {
        const metallib = compileMetalLib(b, ggml_dep);
        b.getInstallStep().dependOn(&b.addInstallFile(metallib, "bin/default.metallib").step);
    }

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

    lib.installHeader(llama_dep.path("tools/mtmd/mtmd.h"), "mtmd.h");
    lib.installHeader(llama_dep.path("tools/mtmd/mtmd-helper.h"), "mtmd-helper.h");

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
        // Upstream split the entry point: main.cpp holds main(), which calls
        // llama_bench() in llama-bench.cpp.
        .files = &.{ "llama-bench.cpp", "main.cpp" },
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
    mtmd: *std.Build.Step.Compile,
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
        // Upstream split the entry point: main.cpp holds main(), which calls
        // llama_cli() in cli.cpp.
        .files = &.{
            "cli.cpp",
            "main.cpp",
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

    // cli.cpp links against server-context (the subset of server files that
    // doesn't pull in the embedded webui assets). Mirrors tools/cli/CMakeLists.txt.
    const server_context_files = [_][]const u8{
        "server-chat.cpp",
        "server-task.cpp",
        "server-queue.cpp",
        "server-common.cpp",
        "server-context.cpp",
        "server-tools.cpp",
    };
    mod.addCSourceFiles(.{
        .root = llama_dep.path("tools/server"),
        .files = &server_context_files,
        .flags = cppflags,
    });

    mod.linkLibrary(mtmd);

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
    mtmd: *std.Build.Step.Compile,
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

    // Upstream's server-http.cpp unconditionally includes a generated "ui.h"
    // and links a `llama-ui` library that embeds the web UI assets. We build
    // without the embedded UI (matching upstream's no-asset fallback): run
    // tools/ui/embed.cpp with no asset directory to generate ui.h/ui.cpp,
    // which provide the llama_ui_* symbols the server needs against an empty
    // asset table.
    const ui_cpp = buildUiEmbed(b, llama_dep, mod);
    mod.addCSourceFile(.{ .file = ui_cpp, .flags = cppflags });

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

    mod.linkLibrary(mtmd);

    const common = buildCommon(b, llama, options);
    mod.linkLibrary(common);

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

// Compile tools/ui/embed.cpp for the build host and run it (with no asset
// directory) to generate the empty-asset ui.cpp/ui.h. The generated header's
// directory is added to `mod`'s include path so both the generated ui.cpp and
// upstream's server-http.cpp can resolve `#include "ui.h"`. Returns the
// generated ui.cpp to be compiled into the server. Mirrors upstream's
// `llama-ui-embed` target.
fn buildUiEmbed(
    b: *std.Build,
    llama_dep: *std.Build.Dependency,
    mod: *std.Build.Module,
) std.Build.LazyPath {
    const embed_mod = b.createModule(.{
        // host build: this tool runs at build time, even when cross-compiling.
        .target = b.graph.host,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .link_libcpp = true,
    });
    embed_mod.addCSourceFile(.{
        .file = llama_dep.path("tools/ui/embed.cpp"),
        .flags = cppflags,
    });
    const embed_exe = b.addExecutable(.{
        .name = "llama-ui-embed",
        .root_module = embed_mod,
    });

    const run = b.addRunArtifact(embed_exe);
    const ui_cpp = run.addOutputFileArg("ui.cpp");
    const ui_h = run.addOutputFileArg("ui.h");
    // no asset-directory argument -> embed.cpp emits an empty asset table.
    mod.addIncludePath(ui_h.dirname());
    return ui_cpp;
}

fn buildDemo(
    b: *std.Build,
    llama: *std.Build.Step.Compile,
    c_mod: *std.Build.Module,
    options: Options,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/demo.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });

    mod.addImport("c", c_mod);
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

fn buildTest(
    b: *std.Build,
    llama: *std.Build.Step.Compile,
    c_mod: *std.Build.Module,
    options: Options,
) void {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/test.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });

    mod.addImport("c", c_mod);
    mod.linkLibrary(llama);

    // workaround until this issue is resolved: https://github.com/ziglang/zig/pull/23936
    mod.lib_paths.appendSlice(b.allocator, llama.root_module.lib_paths.items) catch unreachable;
    if (options.backend == .vulkan) linkVulkanSystem(options.target, mod);

    const tests = b.addTest(.{
        .root_module = mod,
    });

    const run_tests = b.addRunArtifact(tests);
    // Tests load models/TinyStories-656K-Q8_0.gguf via a relative path,
    // so run from the project root.
    run_tests.setCwd(b.path("."));

    const test_step = b.step("test", "Run tests (loads models/TinyStories-656K-Q8_0.gguf)");
    test_step.dependOn(&run_tests.step);
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

fn buildInfoCppSrc(b: *std.Build, options: Options) []const u8 {
    const llama_cpp_commit = commitFromGitUrl(@import("build.zig.zon").dependencies.llama_cpp.url);

    const target = options.target.result;
    const zv = builtin.zig_version;
    const globals = b.fmt(
        \\#include <cstdio>
        \\#include <string>
        \\
        \\int LLAMA_BUILD_NUMBER = 0;
        \\char const *LLAMA_COMMIT = "{s}";
        \\char const *LLAMA_COMPILER = "Zig {d}.{d}.{d}";
        \\char const *LLAMA_BUILD_TARGET = "{s}-{s}-{s}";
        \\
    , .{
        llama_cpp_commit,
        zv.major, zv.minor, zv.patch,
        @tagName(target.cpu.arch), @tagName(target.os.tag), @tagName(target.abi),
    });
    return std.mem.concat(b.allocator, u8, &.{ globals, build_info_funcs }) catch @panic("OOM");
}

const build_info_funcs =
    \\int llama_build_number(void) { return LLAMA_BUILD_NUMBER; }
    \\const char * llama_commit(void) { return LLAMA_COMMIT; }
    \\const char * llama_compiler(void) { return LLAMA_COMPILER; }
    \\const char * llama_build_target(void) { return LLAMA_BUILD_TARGET; }
    \\
    \\const char * llama_build_info(void) {
    \\    static std::string s = "b" + std::to_string(LLAMA_BUILD_NUMBER) + "-" + LLAMA_COMMIT;
    \\    return s.c_str();
    \\}
    \\
    \\void llama_print_build_info(void) {
    \\    fprintf(stderr, "%s: build = %d (%s)\n",      __func__, llama_build_number(), llama_commit());
    \\    fprintf(stderr, "%s: built with %s for %s\n", __func__, llama_compiler(), llama_build_target());
    \\}
;

fn commitFromGitUrl(comptime url: []const u8) []const u8 {
    const hash_idx = comptime std.mem.indexOfScalar(u8, url, '#') orelse
    @compileError("dependency URL is missing '#<commit>' suffix: " ++ url);
    return url[hash_idx + 1 ..];
}

fn listFilesWithExtension(
    b: *std.Build,
    base_path: std.Build.LazyPath,
    ext: []const u8,
) ![]const std.Build.LazyPath {
    const io = b.graph.io;
    var count: usize = 0;

    var iterable_dir = try std.Io.Dir.cwd().openDir(
        io,
        base_path.getPath(b),
        .{
            .iterate = true,
        },
    );
    defer iterable_dir.close(io);
    var it = iterable_dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.endsWith(
            u8,
            entry.name,
            ext,
        )) {
            count += 1;
        }
    }
    it.reader.reset();

    const paths = try b.allocator.alloc(std.Build.LazyPath, count);

    var i: usize = 0;
    while (try it.next(io)) |entry| {
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

fn compileMetalLib(b: *std.Build, ggml_dep: *std.Build.Dependency) std.Build.LazyPath {
    // Compile Metal shaders to .metallib at build time using xcrun
    // The ggml dependency contains the ggml source which has the metal shaders
    const ggml_src = ggml_dep.builder.dependency("ggml", .{});
    const metal_src = ggml_src.path("ggml/src/ggml-metal/ggml-metal.metal");
    const include_path = ggml_src.path("ggml/src");
    const metal_include_path = ggml_src.path("ggml/src/ggml-metal");

    // Step 1: Compile .metal to .air (Metal Intermediate Representation)
    const compile_cmd = b.addSystemCommand(&.{
        "xcrun", "-sdk", "macosx", "metal",
        "-c",
        "-O3",
    });
    compile_cmd.addPrefixedDirectoryArg("-I", include_path);
    compile_cmd.addPrefixedDirectoryArg("-I", metal_include_path);
    compile_cmd.addArg("-o");
    const air_output = compile_cmd.addOutputFileArg("ggml.air");
    compile_cmd.addFileArg(metal_src);

    // Step 2: Link .air to .metallib
    const link_cmd = b.addSystemCommand(&.{
        "xcrun", "-sdk", "macosx", "metallib",
        "-o",
    });
    const metallib_output = link_cmd.addOutputFileArg("default.metallib");
    link_cmd.addFileArg(air_output);

    return metallib_output;
}
