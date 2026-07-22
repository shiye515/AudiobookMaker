# Third-party notices

AudiobookMaker distributes native inference runtimes, but does not distribute any TTS model weights in the application bundle.

| Component | Pinned version | License | Distribution |
| --- | --- | --- | --- |
| sherpa-onnx | 1.13.2 (`13d0ae6c539d2809d32f5eaa3ef1db0c459d0b24`) | Apache-2.0 | Universal dynamic XCFramework in the app |
| ONNX Runtime | 1.24.4 | MIT | Universal dynamic XCFramework in the app |
| Kokoro 82M v1.1 zh | `kokoro-int8-multi-lang-v1_1` | Apache-2.0 (license is included in the downloaded package) | Downloaded only after explicit user action |
| eSpeak NG data | Version contained by the Kokoro package | GPL-3.0-or-later; consult the package notices before redistribution | Downloaded as part of the external model package |
| speech-swift | 0.0.23 (`c1aa219bc2284239ff6917d675a3e1978c840260`) | Apache-2.0 | Audited `AudioCommon`/`MLXCommon`/`CosyVoiceTTS`/`Qwen3TTS` source subset vendored in the app repo; arm64 source unchanged, Intel CAM++ compile-only stub documented in `Vendor/speech-swift/UPSTREAM.md` |
| MLX Swift | 0.31.6 (`0bb916c67f4b9e5c682cbe02a42c701c93ab5021`) | MIT | Swift Package code and generated `mlx.metallib` in the app |
| Swift Transformers | 1.3.3 (`2fa33e1f5e7131a7fc64c28e6d161dcec0d24820`) | Apache-2.0 | Fixed transitive Swift Package dependency used by speech-swift `AudioCommon` |
| CosyVoice3 0.5B MLX 8-bit full | snapshot `b52fc1c3bf5f3b947d40c250639e5ebe347ece11` | Apache-2.0 model metadata | Nine files downloaded only after explicit user action; reference-audio tokenizer weight is excluded |
| Qwen3-TTS 12 Hz 0.6B CustomVoice MLX bf16 | snapshot `3affbf656d9d6aa9255ec0b31cc90055605170bc` | Apache-2.0 | Seven files downloaded only after explicit user action |
| Qwen3-TTS Tokenizer 12 Hz | snapshot `7dd38ad4e9bad454aae9cd937d0cd577604fe229` | Apache-2.0 | Five codec/tokenizer files downloaded with Qwen3-TTS |

The model detail screen links to each pinned source and its declared license. Kokoro also installs a local license file. The release process must review the exact transitive license set whenever the pinned runtime or model manifest changes. Model licenses and acceptable-use terms remain the responsibility of the model publishers; this notice does not grant additional rights.
