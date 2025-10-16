const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // consider building with mcpu=x86_64_v3 for broader compatibility, due to avx
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    mod.addCSourceFiles(.{
        .root = llama_dep.path("src"),
        .files = llama_cpp_src,
        .flags = cppflags,
    });

    const build_info_file = b.addWriteFile("build-info.cpp", build_info_cpp_src);
    mod.addCSourceFiles(.{
        .root = build_info_file.getDirectory(),
        .files = &.{"build-info.cpp"},
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

    mod.addIncludePath(llama_dep.path("common"));
    mod.addIncludePath(llama_dep.path("include"));
    mod.addIncludePath(llama_dep.path("vendor"));

    mod.linkLibrary(ggml_lib);
    mod.lib_paths.appendSlice(b.allocator, ggml_lib.root_module.lib_paths.items) catch unreachable;

    mod.addCSourceFiles(.{
        .root = llama_dep.path("common"),
        .files = common_src,
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

    mod.linkLibrary(llama);
    mod.lib_paths.appendSlice(b.allocator, llama.root_module.lib_paths.items) catch unreachable;

    mod.addCSourceFiles(.{
        .root = llama_dep.path("tools/mtmd"),
        .files = &[_][]const u8{
            "mtmd.cpp",
            "mtmd-audio.cpp",
            "clip.cpp",
            "mtmd-helper.cpp",
        },
        .flags = cppflags,
    });

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
        .root = llama_dep.path("tools/run"),
        .files = &.{
            "run.cpp",
            "linenoise.cpp/linenoise.cpp",
        },
        .flags = cppflags,
    });

    mod.addIncludePath(llama_dep.path("vendor"));
    mod.addIncludePath(llama_dep.path("common"));
    mod.addIncludePath(llama_dep.path("include"));
    mod.addIncludePath(llama_dep.path("ggml/include"));
    mod.addIncludePath(llama_dep.path("tools/run/linenoise.cppflags"));

    mod.linkLibrary(llama);
    mod.lib_paths.appendSlice(b.allocator, llama.root_module.lib_paths.items) catch unreachable;

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
    mod.addCSourceFiles(.{
        .root = llama_dep.path("tools/server"),
        .files = &.{
            "server.cpp",
        },
        .flags = cppflags,
    });

    mod.addIncludePath(llama_dep.path("vendor"));
    mod.addIncludePath(llama_dep.path("common"));
    mod.addIncludePath(llama_dep.path("include"));
    mod.addIncludePath(llama_dep.path("ggml/include"));
    mod.addIncludePath(llama_dep.path("tools/server"));

    mod.linkLibrary(llama);
    mod.lib_paths.appendSlice(b.allocator, llama.root_module.lib_paths.items) catch unreachable;

    const mtmd = buildMTMD(b, llama, options);
    mod.linkLibrary(mtmd);

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

const llama_cpp_src: []const []const u8 = &.{
    "llama.cpp",
    "llama-adapter.cpp",
    "llama-arch.cpp",
    "llama-batch.cpp",
    "llama-chat.cpp",
    "llama-context.cpp",
    "llama-cparams.cpp",
    "llama-grammar.cpp",
    "llama-graph.cpp",
    "llama-hparams.cpp",
    "llama-impl.cpp",
    "llama-io.cpp",
    "llama-kv-cache.cpp",
    "llama-kv-cache-iswa.cpp",
    "llama-memory.cpp",
    "llama-memory-hybrid.cpp",
    "llama-memory-recurrent.cpp",
    "llama-mmap.cpp",
    "llama-model-loader.cpp",
    "llama-model-saver.cpp",
    "llama-model.cpp",
    "llama-quant.cpp",
    "llama-sampling.cpp",
    "llama-vocab.cpp",
    "unicode-data.cpp",
    "unicode.cpp",
};

const common_src: []const []const u8 = &.{
    "arg.cpp",
    "chat-parser.cpp",
    "chat.cpp",
    "common.cpp",
    "console.cpp",
    "json-partial.cpp",
    "json-schema-to-grammar.cpp",
    "llguidance.cpp",
    "log.cpp",
    "ngram-cache.cpp",
    "regex-partial.cpp",
    "sampling.cpp",
    "speculative.cpp",
};
