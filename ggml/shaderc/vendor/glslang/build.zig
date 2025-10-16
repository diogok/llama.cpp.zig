const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var mod = b.addModule(
        "glslang",
        .{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .strip = optimize == .ReleaseSmall,
        },
    );

    const lib = b.addLibrary(.{
        .name = "glslang",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const dep = b.dependency("glslang", .{ .target = target, .optimize = optimize });
    mod.addIncludePath(b.path(""));
    mod.addIncludePath(dep.path(""));
    mod.addIncludePath(dep.path("glslang/Include"));
    mod.addIncludePath(dep.path("glslang/Public"));
    mod.addIncludePath(dep.path("glslang/MachineIndependent"));
    mod.addIncludePath(dep.path("glslang/HLSL"));

    lib.installHeadersDirectory(dep.path(""), "", .{});
    lib.installHeadersDirectory(dep.path("glslang/Include"), "", .{});
    lib.installHeadersDirectory(dep.path("glslang/Public"), "", .{});
    lib.installHeadersDirectory(dep.path("glslang/MachineIndependent"), "", .{});

    mod.addCMacro("ENABLE_HLSL", "1");

    mod.addCSourceFiles(.{
        .root = dep.path("glslang"),
        .files = glslang_src,
        .flags = cpp_flags,
    });

    mod.addCSourceFiles(.{
        .root = dep.path("SPIRV"),
        .files = spirv_src,
        .flags = cpp_flags,
    });
}

const cpp_flags: []const []const u8 = &.{
    "-fPIC",
    "-std=c++17",
    "-O3",
    "-g0",
    "-DENABLE_HLSL",
};

const glslang_src: []const []const u8 = &.{
    "CInterface/glslang_c_interface.cpp",
    "HLSL/hlslAttributes.cpp",
    "HLSL/hlslGrammar.cpp",
    "HLSL/hlslOpMap.cpp",
    "HLSL/hlslParseHelper.cpp",
    "HLSL/hlslParseables.cpp",
    "HLSL/hlslScanContext.cpp",
    "HLSL/hlslTokenStream.cpp",
    "MachineIndependent/Constant.cpp",
    "MachineIndependent/InfoSink.cpp",
    "MachineIndependent/Initialize.cpp",
    "MachineIndependent/IntermTraverse.cpp",
    "MachineIndependent/Intermediate.cpp",
    "MachineIndependent/ParseContextBase.cpp",
    "MachineIndependent/ParseHelper.cpp",
    "MachineIndependent/PoolAlloc.cpp",
    "MachineIndependent/RemoveTree.cpp",
    "MachineIndependent/Scan.cpp",
    "MachineIndependent/ShaderLang.cpp",
    "MachineIndependent/SpirvIntrinsics.cpp",
    "MachineIndependent/SymbolTable.cpp",
    "MachineIndependent/Versions.cpp",
    "MachineIndependent/attribute.cpp",
    "MachineIndependent/glslang_tab.cpp",
    "MachineIndependent/intermOut.cpp",
    "MachineIndependent/iomapper.cpp",
    "MachineIndependent/limits.cpp",
    "MachineIndependent/linkValidate.cpp",
    "MachineIndependent/parseConst.cpp",
    "MachineIndependent/propagateNoContraction.cpp",
    "MachineIndependent/reflection.cpp",
    "MachineIndependent/preprocessor/Pp.cpp",
    "MachineIndependent/preprocessor/PpAtom.cpp",
    "MachineIndependent/preprocessor/PpContext.cpp",
    "MachineIndependent/preprocessor/PpScanner.cpp",
    "MachineIndependent/preprocessor/PpTokens.cpp",
    "GenericCodeGen/CodeGen.cpp",
    "GenericCodeGen/Link.cpp",
};

const spirv_src: []const []const u8 = &.{
    "GlslangToSpv.cpp",
    "InReadableOrder.cpp",
    "Logger.cpp",
    "SpvBuilder.cpp",
    "SpvPostProcess.cpp",
    "SpvTools.cpp",
    "disassemble.cpp",
    "doc.cpp",
};
