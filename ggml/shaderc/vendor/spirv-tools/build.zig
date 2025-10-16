const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule(
        "SPIRV-Tools",
        .{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .strip = optimize == .ReleaseSmall,
        },
    );

    const lib = b.addLibrary(.{
        .name = "SPIRV-Tools",
        .root_module = mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    const spirv_tools = b.dependency("spirv_tools", .{ .target = target, .optimize = optimize });
    mod.addIncludePath(spirv_tools.path("include"));
    mod.addIncludePath(spirv_tools.path(""));
    lib.installHeadersDirectory(
        spirv_tools.path("include"),
        "",
        .{
            .include_extensions = &.{ ".h", ".hpp" },
        },
    );
    lib.installHeadersDirectory(
        spirv_tools.path(""),
        "",
        .{
            .include_extensions = &.{ ".h", ".hpp" },
        },
    );

    const spirv_headers = b.dependency("spirv_headers", .{ .target = target, .optimize = optimize });
    mod.addIncludePath(spirv_headers.path("include"));
    mod.addIncludePath(spirv_headers.path("include/spirv/unified1"));
    lib.installHeadersDirectory(
        spirv_headers.path("include"),
        "",
        .{
            .include_extensions = &.{ ".h", ".hpp", ".inc" },
        },
    );
    lib.installHeadersDirectory(
        spirv_headers.path("include/spirv/unified1"),
        "",
        .{
            .include_extensions = &.{ ".h", ".hpp", ".inc" },
        },
    );

    mod.addIncludePath(b.path("generated"));

    mod.addCSourceFiles(.{
        .root = spirv_tools.path("source"),
        .files = cpp_src,
        .flags = cpp_flags,
    });
    mod.addCSourceFiles(.{
        .root = spirv_tools.path("source/opt"),
        .files = optimizer_src,
        .flags = cpp_flags,
    });
    mod.addCSourceFiles(.{
        .root = spirv_tools.path("source/val"),
        .files = validator_src,
        .flags = cpp_flags,
    });

    switch (target.result.os.tag) {
        .linux => {
            mod.addCMacro("SPIRV_LINUX", "");
        },
        .windows => {
            mod.addCMacro("SPIRV_WINDOWS", "");
        },
        .macos => {
            mod.addCMacro("SPIRV_MAC", "");
        },
        else => {},
    }
}

const cpp_flags: []const []const u8 = &.{
    "-fPIC",
    "-std=c++17",
    "-O3",
    "-g0",
};

const cpp_src: []const []const u8 = &.{
    "assembly_grammar.cpp",
    "binary.cpp",
    "diagnostic.cpp",
    "disassemble.cpp",
    "ext_inst.cpp",
    "extensions.cpp",
    "libspirv.cpp",
    //"mimalloc.cpp",
    "name_mapper.cpp",
    "opcode.cpp",
    "operand.cpp",
    "parsed_operand.cpp",
    "pch_source.cpp",
    "print.cpp",
    "software_version.cpp",
    "spirv_endian.cpp",
    "spirv_fuzzer_options.cpp",
    "spirv_optimizer_options.cpp",
    "spirv_reducer_options.cpp",
    "spirv_target_env.cpp",
    "spirv_validator_options.cpp",
    "table.cpp",
    "table2.cpp",
    "text.cpp",
    "text_handler.cpp",
    "to_string.cpp",
    "util/bit_vector.cpp",
    "util/parse_number.cpp",
    "util/string_utils.cpp",
    "util/timer.cpp",
};

const optimizer_src: []const []const u8 = &.{
    "aggressive_dead_code_elim_pass.cpp",
    "amd_ext_to_khr.cpp",
    "analyze_live_input_pass.cpp",
    "basic_block.cpp",
    "block_merge_pass.cpp",
    "block_merge_util.cpp",
    "build_module.cpp",
    "canonicalize_ids_pass.cpp",
    "ccp_pass.cpp",
    "cfg.cpp",
    "cfg_cleanup_pass.cpp",
    "code_sink.cpp",
    "combine_access_chains.cpp",
    "compact_ids_pass.cpp",
    "composite.cpp",
    "const_folding_rules.cpp",
    "constants.cpp",
    "control_dependence.cpp",
    "convert_to_half_pass.cpp",
    "convert_to_sampled_image_pass.cpp",
    "copy_prop_arrays.cpp",
    "dataflow.cpp",
    "dead_branch_elim_pass.cpp",
    "dead_insert_elim_pass.cpp",
    "dead_variable_elimination.cpp",
    "debug_info_manager.cpp",
    "decoration_manager.cpp",
    "def_use_manager.cpp",
    "desc_sroa.cpp",
    "desc_sroa_util.cpp",
    "dominator_analysis.cpp",
    "dominator_tree.cpp",
    "eliminate_dead_constant_pass.cpp",
    "eliminate_dead_functions_pass.cpp",
    "eliminate_dead_functions_util.cpp",
    "eliminate_dead_io_components_pass.cpp",
    "eliminate_dead_members_pass.cpp",
    "eliminate_dead_output_stores_pass.cpp",
    "feature_manager.cpp",
    "fix_func_call_arguments.cpp",
    "fix_storage_class.cpp",
    "flatten_decoration_pass.cpp",
    "fold.cpp",
    "fold_spec_constant_op_and_composite_pass.cpp",
    "folding_rules.cpp",
    "freeze_spec_constant_value_pass.cpp",
    "function.cpp",
    "graphics_robust_access_pass.cpp",
    "if_conversion.cpp",
    "inline_exhaustive_pass.cpp",
    "inline_opaque_pass.cpp",
    "inline_pass.cpp",
    "instruction.cpp",
    "instruction_list.cpp",
    "interface_var_sroa.cpp",
    "interp_fixup_pass.cpp",
    "invocation_interlock_placement_pass.cpp",
    "ir_context.cpp",
    "ir_loader.cpp",
    "licm_pass.cpp",
    "liveness.cpp",
    "local_access_chain_convert_pass.cpp",
    "local_redundancy_elimination.cpp",
    "local_single_block_elim_pass.cpp",
    "local_single_store_elim_pass.cpp",
    "loop_dependence.cpp",
    "loop_dependence_helpers.cpp",
    "loop_descriptor.cpp",
    "loop_fission.cpp",
    "loop_fusion.cpp",
    "loop_fusion_pass.cpp",
    "loop_peeling.cpp",
    "loop_unroller.cpp",
    "loop_unswitch_pass.cpp",
    "loop_utils.cpp",
    "mem_pass.cpp",
    "merge_return_pass.cpp",
    "modify_maximal_reconvergence.cpp",
    "module.cpp",
    "opextinst_forward_ref_fixup_pass.cpp",
    "optimizer.cpp",
    "pass.cpp",
    "pass_manager.cpp",
    "pch_source_opt.cpp",
    "private_to_local_pass.cpp",
    "propagator.cpp",
    "reduce_load_size.cpp",
    "redundancy_elimination.cpp",
    "register_pressure.cpp",
    "relax_float_ops_pass.cpp",
    "remove_dontinline_pass.cpp",
    "remove_duplicates_pass.cpp",
    "remove_unused_interface_variables_pass.cpp",
    "replace_desc_array_access_using_var_index.cpp",
    "replace_invalid_opc.cpp",
    "resolve_binding_conflicts_pass.cpp",
    "scalar_analysis.cpp",
    "scalar_analysis_simplification.cpp",
    "scalar_replacement_pass.cpp",
    "set_spec_constant_default_value_pass.cpp",
    "simplification_pass.cpp",
    "split_combined_image_sampler_pass.cpp",
    "spread_volatile_semantics.cpp",
    "ssa_rewrite_pass.cpp",
    "strength_reduction_pass.cpp",
    "strip_debug_info_pass.cpp",
    "strip_nonsemantic_info_pass.cpp",
    "struct_cfg_analysis.cpp",
    "struct_packing_pass.cpp",
    "switch_descriptorset_pass.cpp",
    "trim_capabilities_pass.cpp",
    "type_manager.cpp",
    "types.cpp",
    "unify_const_pass.cpp",
    "upgrade_memory_model.cpp",
    "value_number_table.cpp",
    "vector_dce.cpp",
    "workaround1209.cpp",
    "wrap_opkill.cpp",
};

const validator_src: []const []const u8 = &.{
    "basic_block.cpp",
    "construct.cpp",
    "function.cpp",
    "instruction.cpp",
    "validate.cpp",
    "validate_adjacency.cpp",
    "validate_annotation.cpp",
    "validate_arithmetics.cpp",
    "validate_atomics.cpp",
    "validate_barriers.cpp",
    "validate_bitwise.cpp",
    "validate_builtins.cpp",
    "validate_capability.cpp",
    "validate_cfg.cpp",
    "validate_composites.cpp",
    "validate_constants.cpp",
    "validate_conversion.cpp",
    "validate_debug.cpp",
    "validate_decorations.cpp",
    "validate_derivatives.cpp",
    "validate_execution_limitations.cpp",
    "validate_extensions.cpp",
    "validate_function.cpp",
    "validate_graph.cpp",
    "validate_id.cpp",
    "validate_image.cpp",
    "validate_instruction.cpp",
    "validate_interfaces.cpp",
    "validate_invalid_type.cpp",
    "validate_layout.cpp",
    "validate_literals.cpp",
    "validate_logicals.cpp",
    "validate_memory.cpp",
    "validate_memory_semantics.cpp",
    "validate_mesh_shading.cpp",
    "validate_misc.cpp",
    "validate_mode_setting.cpp",
    "validate_non_uniform.cpp",
    "validate_primitives.cpp",
    "validate_ray_query.cpp",
    "validate_ray_tracing.cpp",
    "validate_ray_tracing_reorder.cpp",
    "validate_scopes.cpp",
    "validate_small_type_uses.cpp",
    "validate_tensor.cpp",
    "validate_tensor_layout.cpp",
    "validate_type.cpp",
    "validation_state.cpp",
};
