# GUS local model notice

GUS Mobile is an open-source project. Model files remain with their respective
upstream repositories and are downloaded by the user directly to the iPhone;
they are not bundled in the app, IPA, or CI artifacts. Before a model can be
used, the app verifies its pinned file size and SHA-256 digest.

## Approved models

| Model artifact | File / size | Pinned source | License and attribution |
| --- | --- | --- | --- |
| Qwen1.5-1.8B-Chat Q4_K_M | `qwen1_5-1_8b-chat-q4_k_m.gguf` · 1,217,752,928 bytes | [Qwen GGUF](https://huggingface.co/Qwen/Qwen1.5-1.8B-Chat-GGUF/tree/07800fcba6d5d1df3dfa36e3763374a2c0d9f91b), revision `07800fcba6d5d1df3dfa36e3763374a2c0d9f91b` | [Tongyi Qianwen Research License](https://huggingface.co/Qwen/Qwen1.5-1.8B-Chat-GGUF/blob/07800fcba6d5d1df3dfa36e3763374a2c0d9f91b/LICENSE), non-commercial; GGUF upload by JustinLin610 |
| Qwen2.5-0.5B-Instruct Q4_K_M | `qwen2.5-0.5b-instruct-q4_k_m.gguf` · 491,400,032 bytes | [Qwen GGUF](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/tree/9217f5db79a29953eb74d5343926648285ec7e67), revision `9217f5db79a29953eb74d5343926648285ec7e67` | [Apache 2.0](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/blob/9217f5db79a29953eb74d5343926648285ec7e67/LICENSE); Qwen model family |
| SmolLM2-360M-Instruct Q4_K_M | `smollm2-360m-instruct-q4_k_m.gguf` · 270,590,528 bytes | [GGUF conversion](https://huggingface.co/mfuntowicz/SmolLM2-360M-Instruct-Q4_K_M-GGUF/tree/de67c694b3fa2c6e9b45b50f286b2555c5dee2a8), revision `de67c694b3fa2c6e9b45b50f286b2555c5dee2a8` | [Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0) (model card: [HuggingFaceTB/SmolLM2-360M-Instruct](https://huggingface.co/HuggingFaceTB/SmolLM2-360M-Instruct)); model family by HuggingFaceTB, GGUF uploaded/converted by mfuntowicz |

The application pins each artifact's SHA-256 in its reviewed source manifest.
The digest is displayed in the model screen and checked along with exact size
before installation or loading. Model files live under the app's
`Files > On My iPhone > ISyCode Móvil > ISyCode/GUS/Models` folder. Users may
keep more than one approved model and select one at a time.

For the Qwen1.5 research license, the required attribution is:

> Tongyi Qianwen is licensed under the Tongyi Qianwen RESEARCH LICENSE AGREEMENT, Copyright (c) Alibaba Cloud. All Rights Reserved.

The Qwen1.5 license text is included at
[docs/licenses/TONGYI_QIANWEN_RESEARCH_LICENSE.txt](licenses/TONGYI_QIANWEN_RESEARCH_LICENSE.txt).

## GUS behavior and boundaries

All three models use the same GUS role prompt. The selected model changes the
local inference weights only; it does not change GUS instructions or grant
capabilities. File tools are individually disabled by default and appear to the
model only after the user enables them in the app. Every file mutation still
requires its own visible approval. A strict parser accepts only one tagged call
whose name and arguments match the current tool schema. This feature remains
experimental until model behavior and the approval/denial paths are evaluated
on physical iPhones. Local inference does not fall back to a remote provider.

Starting a download is an explicit user action. iOS background transfers can
continue while the app is suspended or the screen is locked, and iOS may relaunch
the app for transfer events. Force-quitting from the app switcher cancels the
transfer; reopen the app to see whether it can resume or must restart. Network
conditions and iOS scheduling may also delay completion.

Each model's owners and licensors remain third parties; ISyCode Móvil does not
claim to own, author, endorse, or support Qwen, HuggingFaceTB, or the GGUF
converters/uploaders. Users must follow the license for the specific model they
choose. Qwen outputs are not used to train, fine-tune, distill, or create
training data for another model.

## Inference runtime

The iOS runtime is built from [llama.cpp](https://github.com/ggml-org/llama.cpp)
commit `842b1880415d6f508f03b789e5ce70194def7bfd` under the MIT license (copy:
[docs/licenses/LLAMA_CPP_MIT_LICENSE.txt](licenses/LLAMA_CPP_MIT_LICENSE.txt)).
The app does not launch a CLI or subprocess.
