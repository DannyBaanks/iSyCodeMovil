#include "GUSLlamaBridge.h"
#include <llama/llama.h>
#include <stdatomic.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// Spellings of the model's control/user-defined tokens, bucketed by first byte,
// so untrusted message text can never be tokenized as chat framing.
typedef struct {
    char ** texts;
    size_t * lengths;
    size_t count;
    size_t bucket_start[257];  // texts sorted by first byte; [b, b+1) range
} GUSControlSpellings;

struct GUSLlamaContext {
    struct llama_model * model;
    struct llama_context * context;
    atomic_bool cancelled;
    GUSControlSpellings controls;
};

static pthread_once_t backend_once = PTHREAD_ONCE_INIT;
static void initialize_backend(void) { llama_backend_init(); }

static void set_error(char * output, size_t capacity, const char * message) {
    if (output == NULL || capacity == 0) return;
    snprintf(output, capacity, "%s", message == NULL ? "Unknown llama.cpp error" : message);
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1.0e6;
}

static int compare_first_byte(const void * a, const void * b) {
    const unsigned char x = (unsigned char)(*(char * const *)a)[0];
    const unsigned char y = (unsigned char)(*(char * const *)b)[0];
    return (int)x - (int)y;
}

static void free_controls(GUSControlSpellings * controls) {
    for (size_t i = 0; i < controls->count; i++) free(controls->texts[i]);
    free(controls->texts);
    free(controls->lengths);
    memset(controls, 0, sizeof(*controls));
}

static bool collect_controls(const struct llama_vocab * vocab, GUSControlSpellings * out) {
    memset(out, 0, sizeof(*out));
    const int32_t n = llama_vocab_n_tokens(vocab);
    size_t capacity = 64;
    out->texts = malloc(capacity * sizeof(char *));
    if (out->texts == NULL) return false;
    for (int32_t token = 0; token < n; token++) {
        const enum llama_token_attr attr = llama_vocab_get_attr(vocab, token);
        if ((attr & (LLAMA_TOKEN_ATTR_CONTROL | LLAMA_TOKEN_ATTR_USER_DEFINED)) == 0) continue;
        const char * text = llama_vocab_get_text(vocab, token);
        // Single bytes cannot be neutralized without changing the text, and the
        // tokenizer only matches them as special when they appear verbatim.
        if (text == NULL || strlen(text) < 2) continue;
        // Chat framing is always bracketed (<|im_start|>, [INST], <start_of_turn>…).
        // Some vocabularies also register whitespace runs or plain words as
        // user-defined tokens; rewriting those would corrupt ordinary text.
        if (strpbrk(text, "<>[]|") == NULL) continue;
        if (out->count == capacity) {
            capacity *= 2;
            char ** grown = realloc(out->texts, capacity * sizeof(char *));
            if (grown == NULL) { free_controls(out); return false; }
            out->texts = grown;
        }
        out->texts[out->count] = strdup(text);
        if (out->texts[out->count] == NULL) { free_controls(out); return false; }
        out->count++;
    }
    qsort(out->texts, out->count, sizeof(char *), compare_first_byte);
    out->lengths = malloc((out->count ? out->count : 1) * sizeof(size_t));
    if (out->lengths == NULL) { free_controls(out); return false; }
    size_t i = 0;
    for (int b = 0; b < 256; b++) {
        out->bucket_start[b] = i;
        while (i < out->count && (unsigned char)out->texts[i][0] == b) { out->lengths[i] = strlen(out->texts[i]); i++; }
    }
    out->bucket_start[256] = out->count;
    return true;
}

static size_t utf8_char_length(unsigned char lead) {
    if (lead < 0x80) return 1;
    if ((lead & 0xE0) == 0xC0) return 2;
    if ((lead & 0xF0) == 0xE0) return 3;
    if ((lead & 0xF8) == 0xF0) return 4;
    return 1;
}

// Returns a copy of `text` where every occurrence of a control spelling has a
// zero-width space (U+200B) inserted after its first character.
static char * neutralize(const GUSControlSpellings * controls, const char * text) {
    static const char zwsp[] = "\xE2\x80\x8B";
    const size_t length = strlen(text);
    size_t capacity = length + 1 + 64;
    char * out = malloc(capacity);
    if (out == NULL) return NULL;
    size_t w = 0;
    for (size_t r = 0; r < length;) {
        const unsigned char lead = (unsigned char)text[r];
        bool hit = false;
        for (size_t i = controls->bucket_start[lead]; i < controls->bucket_start[lead + 1]; i++) {
            if (controls->lengths[i] <= length - r && memcmp(text + r, controls->texts[i], controls->lengths[i]) == 0) { hit = true; break; }
        }
        size_t step = utf8_char_length(lead);
        if (step > length - r) step = length - r;
        if (w + step + sizeof(zwsp) + 1 > capacity) {
            capacity = capacity * 2 + step + sizeof(zwsp);
            char * grown = realloc(out, capacity);
            if (grown == NULL) { free(out); return NULL; }
            out = grown;
        }
        memcpy(out + w, text + r, step);
        w += step;
        r += step;
        if (hit) { memcpy(out + w, zwsp, sizeof(zwsp) - 1); w += sizeof(zwsp) - 1; }
    }
    out[w] = '\0';
    return out;
}

GUSLlamaContext * gus_llama_create(const char * model_path, uint32_t context_tokens, char * error, size_t error_capacity) {
    if (model_path == NULL || context_tokens < 512 || context_tokens > 4096) {
        set_error(error, error_capacity, "Invalid model path or unsupported context size (allowed: 512–4096). ");
        return NULL;
    }
    pthread_once(&backend_once, initialize_backend);

    struct llama_model_params model_params = llama_model_default_params();
    model_params.n_gpu_layers = -1;
    struct llama_model * model = llama_model_load_from_file(model_path, model_params);
    if (model == NULL) {
        set_error(error, error_capacity, "llama.cpp could not load the verified GGUF.");
        return NULL;
    }

    struct llama_context_params context_params = llama_context_default_params();
    context_params.n_ctx = context_tokens;
    context_params.n_batch = context_tokens < 256 ? context_tokens : 256;
    context_params.n_ubatch = context_params.n_batch;
    context_params.n_threads = 4;
    context_params.n_threads_batch = 4;
    struct llama_context * context = llama_init_from_model(model, context_params);
    if (context == NULL) {
        llama_model_free(model);
        set_error(error, error_capacity, "llama.cpp could not allocate the requested context.");
        return NULL;
    }

    GUSLlamaContext * result = calloc(1, sizeof(GUSLlamaContext));
    if (result == NULL || !collect_controls(llama_model_get_vocab(model), &result->controls)) {
        free(result);
        llama_free(context);
        llama_model_free(model);
        set_error(error, error_capacity, "Not enough memory for the inference context.");
        return NULL;
    }
    result->model = model;
    result->context = context;
    atomic_init(&result->cancelled, false);
    return result;
}

void gus_llama_destroy(GUSLlamaContext * context) {
    if (context == NULL) return;
    llama_free(context->context);
    llama_model_free(context->model);
    free_controls(&context->controls);
    free(context);
}

void gus_llama_cancel(GUSLlamaContext * context) {
    if (context != NULL) atomic_store(&context->cancelled, true);
}

GUSSamplingParams gus_llama_default_chat_sampling(void) {
    GUSSamplingParams p;
    p.temperature = 0.6f;
    p.top_p = 0.9f;
    p.min_p = 0.05f;
    p.top_k = 40;
    p.repeat_penalty = 1.15f;
    p.repeat_last_n = 128;
    p.seed = LLAMA_DEFAULT_SEED;
    return p;
}

static struct llama_sampler * make_sampler(const struct llama_vocab * vocab, const GUSSamplingParams * p) {
    struct llama_sampler_chain_params params = llama_sampler_chain_default_params();
    struct llama_sampler * chain = llama_sampler_chain_init(params);
    if (chain == NULL) return NULL;
    if (p == NULL) {
        llama_sampler_chain_add(chain, llama_sampler_init_greedy());
        return chain;
    }
    // Penalties scan candidates, so narrow them with top-k first (llama.h advice).
    if (p->top_k > 0) llama_sampler_chain_add(chain, llama_sampler_init_top_k(p->top_k));
    if (p->repeat_penalty > 1.0f && p->repeat_last_n > 0) {
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), p->repeat_last_n,
                                                                    p->repeat_penalty, 0.0f, 0.0f));
    }
    if (p->top_p > 0.0f && p->top_p < 1.0f) llama_sampler_chain_add(chain, llama_sampler_init_top_p(p->top_p, 1));
    if (p->min_p > 0.0f) llama_sampler_chain_add(chain, llama_sampler_init_min_p(p->min_p, 1));
    llama_sampler_chain_add(chain, llama_sampler_init_temp(p->temperature > 0.0f ? p->temperature : 0.6f));
    llama_sampler_chain_add(chain, llama_sampler_init_dist(p->seed));
    return chain;
}

/// Picks the next token under a grammar.
///
/// The chain samples first and the grammar only checks that one token: running the
/// grammar over the whole vocabulary on every step is far slower, and most tokens a
/// model proposes are already valid. Only when the proposal is rejected is the full
/// candidate list filtered by the grammar and sampled again. Returns false when the
/// grammar leaves nothing to emit.
static bool sample_constrained(struct llama_sampler * chain, struct llama_sampler * grammar,
                               struct llama_context * context, llama_token_data * candidates,
                               int32_t vocab_size, llama_token * out) {
    const float * logits = llama_get_logits_ith(context, -1);
    if (logits == NULL) return false;
    for (int32_t id = 0; id < vocab_size; id++) {
        candidates[id] = (llama_token_data){ id, logits[id], 0.0f };
    }
    llama_token_data_array all = { candidates, (size_t)vocab_size, -1, false };
    llama_sampler_apply(chain, &all);
    if (all.selected < 0 || (size_t)all.selected >= all.size) return false;
    llama_token token = all.data[all.selected].id;

    llama_token_data proposal = { token, 1.0f, 0.0f };
    llama_token_data_array single = { &proposal, 1, -1, false };
    llama_sampler_apply(grammar, &single);
    if (proposal.logit == -INFINITY) {
        for (int32_t id = 0; id < vocab_size; id++) {
            candidates[id] = (llama_token_data){ id, logits[id], 0.0f };
        }
        llama_token_data_array allowed = { candidates, (size_t)vocab_size, -1, false };
        llama_sampler_apply(grammar, &allowed);
        llama_sampler_apply(chain, &allowed);
        if (allowed.selected < 0 || (size_t)allowed.selected >= allowed.size) return false;
        if (allowed.data[allowed.selected].logit == -INFINITY) return false;
        token = allowed.data[allowed.selected].id;
    }
    llama_sampler_accept(grammar, token);
    llama_sampler_accept(chain, token);
    *out = token;
    return true;
}

static char * generate_from_prompt(GUSLlamaContext * state, const char * prompt, uint32_t max_tokens,
                                   const GUSSamplingParams * sampling, const char * grammar_text,
                                   GUSGenerationStats * stats, char * error, size_t error_capacity) {
    atomic_store(&state->cancelled, false);
    llama_memory_clear(llama_get_memory(state->context), true);

    const struct llama_vocab * vocab = llama_model_get_vocab(state->model);
    size_t prompt_length = strlen(prompt);
    if (prompt_length > (size_t)INT32_MAX - 16) {
        set_error(error, error_capacity, "Prompt is too large to tokenize safely.");
        return NULL;
    }
    int32_t token_capacity = (int32_t)prompt_length + 16;
    llama_token * tokens = calloc((size_t)token_capacity, sizeof(llama_token));
    if (tokens == NULL) {
        set_error(error, error_capacity, "Not enough memory to tokenize the prompt.");
        return NULL;
    }
    int32_t token_count = llama_tokenize(vocab, prompt, (int32_t)prompt_length, tokens, token_capacity, true, true);
    if (token_count < 0) {
        int32_t required = -token_count;
        llama_token * larger = realloc(tokens, (size_t)required * sizeof(llama_token));
        if (larger == NULL) { free(tokens); set_error(error, error_capacity, "Not enough memory to tokenize the prompt."); return NULL; }
        tokens = larger;
        token_count = llama_tokenize(vocab, prompt, (int32_t)prompt_length, tokens, required, true, true);
    }
    if (token_count <= 0 || (uint32_t)token_count + max_tokens > llama_n_ctx(state->context)) {
        free(tokens);
        set_error(error, error_capacity, "Prompt exceeds the selected local context window.");
        return NULL;
    }
    if (stats != NULL) stats->prompt_tokens = token_count;

    // llama_decode has a hard n_batch limit (256 in our iOS context). Sending
    // the full conversation as one batch works for the first short prompt, but
    // a second turn includes the previous answer and can exceed that limit;
    // llama.cpp asserts in that case and terminates the app. Prefill in
    // sequential chunks so the memory positions continue across the prompt.
    const uint32_t batch_limit = llama_n_batch(state->context);
    if (batch_limit == 0) {
        free(tokens);
        set_error(error, error_capacity, "llama.cpp reported an invalid prompt batch size.");
        return NULL;
    }
    const double prefill_start = now_ms();
    for (int32_t offset = 0; offset < token_count;) {
        if (atomic_load(&state->cancelled)) {
            free(tokens);
            set_error(error, error_capacity, "Generation cancelled.");
            return NULL;
        }
        const int32_t remaining = token_count - offset;
        const int32_t chunk_size = remaining < (int32_t)batch_limit
            ? remaining
            : (int32_t)batch_limit;
        struct llama_batch prompt_batch = llama_batch_get_one(tokens + offset, chunk_size);
        if (llama_decode(state->context, prompt_batch) != 0) {
            free(tokens);
            set_error(error, error_capacity, "llama.cpp failed while evaluating the prompt.");
            return NULL;
        }
        offset += chunk_size;
    }
    free(tokens);
    const double generate_start = now_ms();
    if (stats != NULL) stats->prefill_ms = generate_start - prefill_start;

    struct llama_sampler * sampler = make_sampler(vocab, sampling);
    if (sampler == NULL) { set_error(error, error_capacity, "Could not initialize local sampler."); return NULL; }

    struct llama_sampler * grammar = NULL;
    llama_token_data * candidates = NULL;
    const int32_t vocab_size = llama_vocab_n_tokens(vocab);
    if (grammar_text != NULL) {
        grammar = llama_sampler_init_grammar(vocab, grammar_text, "root");
        if (grammar == NULL) {
            llama_sampler_free(sampler);
            set_error(error, error_capacity, "The tool grammar could not be parsed.");
            return NULL;
        }
        candidates = calloc((size_t)vocab_size, sizeof(llama_token_data));
        if (candidates == NULL) {
            llama_sampler_free(grammar);
            llama_sampler_free(sampler);
            set_error(error, error_capacity, "Not enough memory for constrained sampling.");
            return NULL;
        }
    }

    size_t output_capacity = (size_t)max_tokens * 32 + 1;
    char * output = calloc(output_capacity, 1);
    if (output == NULL) {
        free(candidates);
        if (grammar != NULL) llama_sampler_free(grammar);
        llama_sampler_free(sampler);
        set_error(error, error_capacity, "Not enough memory for generated text.");
        return NULL;
    }
    size_t output_length = 0;
    int32_t generated = 0;
    int32_t stopped_at_eog = 0;
    char piece[512];
    for (uint32_t index = 0; index < max_tokens; index++) {
        if (atomic_load(&state->cancelled)) {
            free(output);
            free(candidates);
            if (grammar != NULL) llama_sampler_free(grammar);
            llama_sampler_free(sampler);
            set_error(error, error_capacity, "Generation cancelled.");
            return NULL;
        }
        llama_token token;
        if (grammar != NULL) {
            // Nothing left that the grammar accepts: the sentence is complete.
            if (!sample_constrained(sampler, grammar, state->context, candidates, vocab_size, &token)) {
                stopped_at_eog = 1;
                break;
            }
        } else {
            token = llama_sampler_sample(sampler, state->context, -1);
        }
        if (llama_vocab_is_eog(vocab, token)) { stopped_at_eog = 1; break; }
        // llama_sampler_sample() already accepted the token; accepting it again
        // would count every token twice in the repetition penalty.
        generated++;
        int32_t piece_length = llama_token_to_piece(vocab, token, piece, (int32_t)sizeof(piece), 0, false);
        if (piece_length > 0 && output_length + (size_t)piece_length < output_capacity) {
            memcpy(output + output_length, piece, (size_t)piece_length);
            output_length += (size_t)piece_length;
            output[output_length] = '\0';
        }
        struct llama_batch next = llama_batch_get_one(&token, 1);
        if (llama_decode(state->context, next) != 0) {
            free(output);
            free(candidates);
            if (grammar != NULL) llama_sampler_free(grammar);
            llama_sampler_free(sampler);
            set_error(error, error_capacity, "llama.cpp failed while generating a response.");
            return NULL;
        }
    }
    free(candidates);
    if (grammar != NULL) llama_sampler_free(grammar);
    llama_sampler_free(sampler);
    if (stats != NULL) {
        stats->generate_ms = now_ms() - generate_start;
        stats->generated_tokens = generated;
        stats->stopped_at_eog = stopped_at_eog;
    }
    return output;
}

char * gus_llama_generate(GUSLlamaContext * state, const char * prompt, uint32_t max_tokens, char * error, size_t error_capacity) {
    if (state == NULL || prompt == NULL || max_tokens == 0 || max_tokens > 512) {
        set_error(error, error_capacity, "Invalid inference request.");
        return NULL;
    }
    return generate_from_prompt(state, prompt, max_tokens, NULL, NULL, NULL, error, error_capacity);
}

static bool valid_role(const char * role) {
    return role != NULL && (strcmp(role, "system") == 0 || strcmp(role, "user") == 0 || strcmp(role, "assistant") == 0);
}

static int32_t apply_template(const char * tmpl, const struct llama_chat_message * chat, size_t count,
                              char ** buffer, int32_t * capacity) {
    int32_t needed = llama_chat_apply_template(tmpl, chat, count, true, *buffer, *capacity);
    if (needed > *capacity) {
        char * grown = realloc(*buffer, (size_t)needed + 1);
        if (grown == NULL) return -2;
        *buffer = grown;
        *capacity = needed + 1;
        needed = llama_chat_apply_template(tmpl, chat, count, true, *buffer, *capacity);
    }
    return needed;
}

char * gus_llama_format_chat(GUSLlamaContext * state, const GUSChatMessage * messages, size_t message_count,
                             const char * template_override, int32_t * template_source,
                             char * error, size_t error_capacity) {
    if (state == NULL || messages == NULL || message_count == 0 || message_count > 256) {
        set_error(error, error_capacity, "Invalid chat request.");
        return NULL;
    }
    struct llama_chat_message * chat = calloc(message_count, sizeof(struct llama_chat_message));
    char ** owned = calloc(message_count, sizeof(char *));
    if (chat == NULL || owned == NULL) {
        free(chat); free(owned);
        set_error(error, error_capacity, "Not enough memory to format the chat.");
        return NULL;
    }
    size_t total = 0;
    char * result = NULL;
    for (size_t i = 0; i < message_count; i++) {
        if (!valid_role(messages[i].role) || messages[i].content == NULL) {
            set_error(error, error_capacity, "Chat messages need a system/user/assistant role and content.");
            goto done;
        }
        owned[i] = neutralize(&state->controls, messages[i].content);
        if (owned[i] == NULL) { set_error(error, error_capacity, "Not enough memory to format the chat."); goto done; }
        chat[i].role = messages[i].role;
        chat[i].content = owned[i];
        total += strlen(owned[i]) + 64;
    }
    if (total > (size_t)INT32_MAX / 2) { set_error(error, error_capacity, "Chat is too large."); goto done; }

    int32_t capacity = (int32_t)(total * 2 + 256);
    result = malloc((size_t)capacity);
    if (result == NULL) { set_error(error, error_capacity, "Not enough memory to format the chat."); goto done; }

    int32_t source = GUS_TEMPLATE_OVERRIDE;
    const char * tmpl = template_override;
    if (tmpl == NULL) {
        source = GUS_TEMPLATE_EMBEDDED;
        tmpl = llama_model_chat_template(state->model, NULL);
    }
    int32_t written = tmpl != NULL ? apply_template(tmpl, chat, message_count, &result, &capacity) : -1;
    if (written == -1 && template_override != NULL) {
        set_error(error, error_capacity, "The catalog chat template is not supported by this llama.cpp build.");
        free(result); result = NULL;
        goto done;
    }
    if (written == -1) {
        source = GUS_TEMPLATE_FALLBACK;
        written = apply_template("chatml", chat, message_count, &result, &capacity);
    }
    if (written < 0) {
        set_error(error, error_capacity, "Could not format the chat for this model.");
        free(result); result = NULL;
        goto done;
    }
    result[written < capacity ? written : capacity - 1] = '\0';
    if (template_source != NULL) *template_source = source;

done:
    for (size_t i = 0; i < message_count; i++) free(owned[i]);
    free(owned);
    free(chat);
    return result;
}

char * gus_llama_generate_chat(GUSLlamaContext * state, const GUSChatMessage * messages, size_t message_count,
                               const char * template_override, uint32_t max_tokens,
                               GUSGenerationStats * stats, char * error, size_t error_capacity) {
    return gus_llama_generate_chat_sampled(state, messages, message_count, template_override, max_tokens,
                                           NULL, stats, error, error_capacity);
}

char * gus_llama_generate_chat_sampled(GUSLlamaContext * state, const GUSChatMessage * messages, size_t message_count,
                                       const char * template_override, uint32_t max_tokens,
                                       const GUSSamplingParams * sampling,
                                       GUSGenerationStats * stats, char * error, size_t error_capacity) {
    return gus_llama_generate_chat_constrained(state, messages, message_count, template_override, max_tokens,
                                               sampling, NULL, stats, error, error_capacity);
}

char * gus_llama_generate_chat_constrained(GUSLlamaContext * state, const GUSChatMessage * messages, size_t message_count,
                                           const char * template_override, uint32_t max_tokens,
                                           const GUSSamplingParams * sampling, const char * grammar,
                                           GUSGenerationStats * stats, char * error, size_t error_capacity) {
    if (max_tokens == 0 || max_tokens > 512) {
        set_error(error, error_capacity, "Invalid inference request.");
        return NULL;
    }
    if (stats != NULL) memset(stats, 0, sizeof(*stats));
    int32_t source = GUS_TEMPLATE_FALLBACK;
    char * prompt = gus_llama_format_chat(state, messages, message_count, template_override, &source, error, error_capacity);
    if (prompt == NULL) return NULL;
    if (stats != NULL) stats->template_source = source;
    char * output = generate_from_prompt(state, prompt, max_tokens, sampling, grammar, stats, error, error_capacity);
    free(prompt);
    return output;
}

char * gus_llama_model_description(GUSLlamaContext * state) {
    if (state == NULL) return NULL;
    char desc[256] = {0};
    llama_model_desc(state->model, desc, sizeof(desc));
    char * out = malloc(384);
    if (out == NULL) return NULL;
    snprintf(out, 384, "%s; params=%llu; size=%llu; ctx=%u", desc,
             (unsigned long long)llama_model_n_params(state->model),
             (unsigned long long)llama_model_size(state->model),
             llama_n_ctx(state->context));
    return out;
}

void gus_llama_free_text(char * text) { free(text); }
