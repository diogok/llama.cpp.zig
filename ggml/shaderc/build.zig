const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var shaderc_mod = b.addModule(
        "shaderc",
        .{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .strip = optimize == .ReleaseSmall,
        },
    );

    const shaderc_lib = b.addLibrary(.{
        .name = "shaderc",
        .root_module = shaderc_mod,
        .linkage = .static,
    });

    b.installArtifact(shaderc_lib);

    const shaderc_dep = b.dependency("shaderc", .{ .target = target, .optimize = optimize });
    shaderc_mod.addIncludePath(shaderc_dep.path("libshaderc/include"));
    shaderc_mod.addIncludePath(shaderc_dep.path("libshaderc_util/include"));

    shaderc_lib.installHeadersDirectory(
        shaderc_dep.path("libshaderc/include"),
        "",
        .{
            .include_extensions = &.{ ".h", ".hpp", ".inc" },
        },
    );
    shaderc_lib.installHeadersDirectory(
        shaderc_dep.path("libshaderc_util/include"),
        "",
        .{
            .include_extensions = &.{ ".h", ".hpp", ".inc" },
        },
    );

    const spirv_tools_dep = b.dependency("spirv_tools", .{ .target = target, .optimize = optimize });
    const spirv_tools_lib = spirv_tools_dep.artifact("SPIRV-Tools");
    shaderc_mod.linkLibrary(spirv_tools_lib);
    shaderc_lib.installLibraryHeaders(spirv_tools_lib);

    const glslang_dep = b.dependency("glslang", .{ .target = target, .optimize = optimize });
    const glslang_lib = glslang_dep.artifact("glslang");
    shaderc_mod.linkLibrary(glslang_lib);
    shaderc_lib.installLibraryHeaders(glslang_lib);
    shaderc_mod.addCMacro("ENABLE_HLSL", "1");

    shaderc_mod.addCSourceFiles(.{
        .root = shaderc_dep.path("libshaderc/src"),
        .files = &.{"shaderc.cc"},
        .flags = cpp_flags,
    });

    shaderc_mod.addCSourceFiles(.{
        .root = shaderc_dep.path("libshaderc/include/shaderc"),
        .files = &.{"shaderc.hpp"},
        .flags = cpp_flags,
    });

    shaderc_mod.addCSourceFiles(.{
        .root = shaderc_dep.path("libshaderc_util/src"),
        .files = &.{
            "args.cc",
            "compiler.cc",
            "file_finder.cc",
            "io_shaderc.cc",
            "message.cc",
            "resources.cc",
            "shader_stage.cc",
            "spirv_tools_wrapper.cc",
            "version_profile.cc",
        },
        .flags = cpp_flags,
    });

    const glslc_mod = b.addModule(
        "glslc",
        .{
            .target = target,
            .optimize = optimize,
            .strip = .optmize == .ReleaseSmall,
            .link_libc = true,
            .link_libcpp = true,
        },
    );

    glslc_mod.linkLibrary(shaderc_lib);

    glslc_mod.addIncludePath(shaderc_dep.path("glslc/src"));
    glslc_mod.addIncludePath(shaderc_dep.path("src"));
    glslc_mod.addIncludePath(b.path("")); // for build-version.inc

    glslc_mod.addCSourceFiles(.{
        .root = shaderc_dep.path("glslc/src"),
        .files = &[_][]const u8{
            "dependency_info.cc",
            "file.cc",
            "file_compiler.cc",
            "file_includer.cc",
            "main.cc",
            "resource_parse.cc",
            "shader_stage.cc",
        },
        .flags = cpp_flags,
    });

    const glsc_exe = b.addExecutable(.{
        .name = "glslc",
        .root_module = glslc_mod,
    });
    b.installArtifact(glsc_exe);
}

const cpp_flags: []const []const u8 = &.{
    "-fPIC",
    "-std=c++17",
    "-O3",
    "-g0",
};
