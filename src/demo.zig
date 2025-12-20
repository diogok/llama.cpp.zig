const std = @import("std");

const c = @cImport({
    @cInclude("llama.h");
});

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() != .leak);
    const allocator = gpa.allocator();

    // init
    c.llama_backend_init();
    defer c.llama_backend_free();

    // load model
    var params = c.llama_model_default_params();
    params.n_gpu_layers = 99;

    const model = c.llama_model_load_from_file("models/TinyStories-656K-Q8_0.gguf", params);
    defer c.llama_model_free(model);

    if (model == null) {
        return error.FailedToLoadModel;
    }

    // TODO: ideally should apply chat templates here
    try generate(allocator, model, "Hello");
    try generate(allocator, model, "Goodbye");
}

fn generate(
    allocator: std.mem.Allocator,
    model: ?*c.llama_model,
    prompt: []const u8,
) !void {
    const vocab = c.llama_model_get_vocab(model);

    // init context
    const model_ctx_train = c.llama_model_n_ctx_train(model);
    var context_params = c.llama_context_default_params();
    if (model_ctx_train <= 0) {
        context_params.n_ctx = 0;
    } else {
        context_params.n_ctx = @abs(model_ctx_train);
    }
    context_params.n_batch = context_params.n_ctx / 2;
    context_params.n_ubatch = context_params.n_ctx / 8;
    context_params.no_perf = true;

    const context = c.llama_init_from_model(model, context_params);
    defer c.llama_free(context);
    if (context == null) {
        return error.FailedToInitContext;
    }

    // init sampler
    var sampler_params = c.llama_sampler_chain_default_params();
    sampler_params.no_perf = true;
    const sampler = c.llama_sampler_chain_init(sampler_params);
    defer c.llama_sampler_free(sampler);
    c.llama_sampler_chain_add(sampler, c.llama_sampler_init_greedy());
    c.llama_sampler_chain_add(sampler, c.llama_sampler_init_top_k(40));
    c.llama_sampler_chain_add(sampler, c.llama_sampler_init_top_p(0.9, 1));
    c.llama_sampler_chain_add(sampler, c.llama_sampler_init_min_p(0.05, 1));
    c.llama_sampler_chain_add(sampler, c.llama_sampler_init_temp(0.6));
    c.llama_sampler_chain_add(sampler, c.llama_sampler_init_dist(c.LLAMA_DEFAULT_SEED));

    // tokenize prompt
    const prompt_token_len = -c.llama_tokenize(
        vocab,
        prompt.ptr,
        @intCast(prompt.len),
        null,
        0,
        true,
        true,
    );
    const prompt_tokens = try allocator.alloc(c.llama_token, @abs(prompt_token_len));
    defer allocator.free(prompt_tokens);

    const tokenize_prompt_result = c.llama_tokenize(
        vocab,
        prompt.ptr,
        @intCast(prompt.len),
        prompt_tokens.ptr,
        prompt_token_len,
        true,
        true,
    );
    if (tokenize_prompt_result < 0) {
        return error.FailedToTokenizePrompt;
    }

    // init batch
    var batch = c.llama_batch_get_one(prompt_tokens.ptr, @intCast(prompt_tokens.len));

    if (c.llama_model_has_encoder(model)) {
        const encode_r = c.llama_encode(context, batch);
        if (encode_r != 0) {
            std.log.err("failed to encode: {d}", .{encode_r});
            return error.FailedToEncodePrompt;
        }
        var decoder_token = c.llama_model_decoder_start_token(model);
        if (decoder_token == c.LLAMA_TOKEN_NULL) {
            decoder_token = c.llama_vocab_bos(vocab);
        }
        batch = c.llama_batch_get_one(&decoder_token, 1);
    }

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("{s}\n", .{prompt});

    // track tokens and limits
    const limit: usize = @intCast(c.llama_n_ctx(context));
    var count: usize = prompt_tokens.len;

    // eval loop
    eval: while (count <= limit) : (count += 1) {
        const decode_r = c.llama_decode(context, batch);
        if (decode_r > 0) {
            std.log.err("failed to eval: {d}", .{decode_r});
            break :eval;
        }

        var token_id = c.llama_sampler_sample(sampler, context, -1);

        if (c.llama_vocab_is_eog(vocab, token_id)) {
            break :eval;
        }

        var buffer: [128]u8 = undefined;
        const piece_len = c.llama_token_to_piece(
            vocab,
            token_id,
            (&buffer).ptr,
            buffer.len,
            0,
            true,
        );
        if (piece_len < 0) {
            std.log.err("failed to convert token to piece", .{});
            break :eval;
        }
        _ = try out.write(buffer[0..@abs(piece_len)]);
        batch = c.llama_batch_get_one(&token_id, 1);
    }

    try out.print("\n", .{});
    try out.flush();
}
