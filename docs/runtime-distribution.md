# Runtime and model distribution

AudiobookMaker is built and released only for native Apple Silicon (`arm64`). The App, unit-test target, UI-test target, embedded Swift libraries, generated MLX Metal library, archive, signing, and release checks all use the same architecture boundary. Intel, Rosetta, and Universal 2 artifacts are not produced.

The app uses two retained runtime paths:

1. Apple system speech through AVFoundation; it is available without downloading a model.
2. CosyVoice3 and Qwen3-TTS through the audited source subset in `Vendor/speech-swift`, MLX Swift 0.31.6, Swift Transformers 1.3.3, and `Contents/Resources/MLX/mlx.metallib`.

`Vendor/speech-swift/UPSTREAM.md` records the exact speech-swift 0.0.23 revision and vendored subtree identities. The reduced package contains only `AudioCommon`, `MLXCommon`, `CosyVoiceTTS`, and `Qwen3TTS`. `Tools/Dependencies/build-mlx-metallib.sh` fails the build when the Metal toolchain, kernel sources, or generated metallib are unavailable.

## Explicit model download

No TTS weights ship in the repository or App bundle. The model screen offers two signed, pinned snapshots:

- CosyVoice3 0.5B MLX 8-bit: 1,121,605,600 bytes
- Qwen3-TTS 0.6B CustomVoice MLX bf16 plus tokenizer: 2,498,418,367 bytes

The installer starts networking only after explicit user action. It accepts the exact HTTPS origins and redirect hosts declared by the signed manifest, checks disk capacity, verifies every artifact size and SHA-256, rejects unsafe paths/links, writes a content receipt, and atomically commits one model version below `Application Support/AudiobookMaker/Runtime/Models`. Runtime loading uses offline mode and fails if any required file or receipt is invalid.

## Runtime safety

Before download or MLX initialization, platform support verifies native arm64, the minimum macOS version, a Metal device, and the bundled MLX runtime resource. A failed check returns a stable unavailable state and does not create a model session.

The runtime reuses the verified session for consecutive fragments with the same model/version. Switching model, an unrecoverable error, or idle memory pressure unloads the rebuildable session. Effective concurrency is the minimum of user configuration, runtime recommendation, and model safety limit. Text is split at sentence boundaries under character/token and generated-duration budgets. Cancellation stops later submissions and discards results that arrive after the cancellation boundary.

## Release gate

`Tools/archive-apple-silicon.sh` creates the Release archive with `ARCHS=arm64`, invokes `Tools/verify-release-artifacts.sh`, verifies the signature, and optionally submits/staples when `NOTARY_PROFILE` is set. The verifier recursively:

- requires every Mach-O file to contain exactly the arm64 slice;
- scans each Mach-O link graph for removed runtime dependencies;
- rejects removed runtime paths and bundled model-weight formats.

The same gate is run by `.github/workflows/apple-silicon-release-gate.yml`. Performance collection and regression comparison are documented in `docs/apple-silicon-performance.md`.
