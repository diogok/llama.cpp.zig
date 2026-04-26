const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("llama.h");
});

const model_path = "models/TinyStories-656K-Q8_0.gguf";

// Greedy generation is deterministic: same model + same prompt → same tokens.
// These tests double as a smoke test that llama.cpp built and links correctly.

test "build smoke: backend init and model load" {
    c.llama_backend_init();
    defer c.llama_backend_free();

    var params = c.llama_model_default_params();
    params.n_gpu_layers = 0;

    const model = c.llama_model_load_from_file(model_path, params);
    defer c.llama_model_free(model);
    try testing.expect(model != null);

    const vocab = c.llama_model_get_vocab(model);
    try testing.expect(vocab != null);
}

test "greedy generation: Once upon a time" {
    const out = try greedyGenerate(testing.allocator, "Once upon a time", 32);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        ", a little girl named Lily lived in a small house. She loved to eat yummy food. One day, she saw a small bird on the ground. The bird was sad because it could not eat it.\nLily wanted to help the bird. She tried to eat the food and ",
        out,
    );
}

test "greedy generation: Hello" {
    const out = try greedyGenerate(testing.allocator, "Hello", 16);
    defer testing.allocator.free(out);

    try testing.expectEqualStrings(
        " and a girl were walking in the park. One day she saw a small bird flying in the sk",
        out,
    );
}

fn greedyGenerate(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    max_new_tokens: usize,
) ![]u8 {
    c.llama_backend_init();
    defer c.llama_backend_free();

    var model_params = c.llama_model_default_params();
    model_params.n_gpu_layers = 0;

    const model = c.llama_model_load_from_file(model_path, model_params);
    defer c.llama_model_free(model);
    if (model == null) return error.FailedToLoadModel;

    const vocab = c.llama_model_get_vocab(model);

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
    if (context == null) return error.FailedToInitContext;

    var sampler_params = c.llama_sampler_chain_default_params();
    sampler_params.no_perf = true;
    const sampler = c.llama_sampler_chain_init(sampler_params);
    defer c.llama_sampler_free(sampler);
    c.llama_sampler_chain_add(sampler, c.llama_sampler_init_greedy());

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
    if (tokenize_prompt_result < 0) return error.FailedToTokenizePrompt;

    var batch = c.llama_batch_get_one(prompt_tokens.ptr, @intCast(prompt_tokens.len));

    if (c.llama_model_has_encoder(model)) {
        const encode_r = c.llama_encode(context, batch);
        if (encode_r != 0) return error.FailedToEncodePrompt;
        var decoder_token = c.llama_model_decoder_start_token(model);
        if (decoder_token == c.LLAMA_TOKEN_NULL) {
            decoder_token = c.llama_vocab_bos(vocab);
        }
        batch = c.llama_batch_get_one(&decoder_token, 1);
    }

    var output = std.array_list.Managed(u8).init(allocator);
    errdefer output.deinit();

    var generated: usize = 0;
    while (generated < max_new_tokens) : (generated += 1) {
        const decode_r = c.llama_decode(context, batch);
        if (decode_r > 0) return error.FailedToDecode;

        var token_id = c.llama_sampler_sample(sampler, context, -1);

        if (c.llama_vocab_is_eog(vocab, token_id)) break;

        var buffer: [128]u8 = undefined;
        const piece_len = c.llama_token_to_piece(
            vocab,
            token_id,
            (&buffer).ptr,
            buffer.len,
            0,
            true,
        );
        if (piece_len < 0) return error.FailedToConvertTokenToPiece;
        try output.appendSlice(buffer[0..@abs(piece_len)]);
        batch = c.llama_batch_get_one(&token_id, 1);
    }

    return output.toOwnedSlice();
}
