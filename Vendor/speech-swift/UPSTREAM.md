# speech-swift vendored runtime subset

This directory contains only the `AudioCommon`, `MLXCommon`, `CosyVoiceTTS`, and
`Qwen3TTS` targets required by AudiobookMaker. The source is copied verbatim from
soniqo/speech-swift v0.0.23 at revision
`c1aa219bc2284239ff6917d675a3e1978c840260`, except for the documented Intel
compile-only stub in `Sources/CosyVoiceTTS/CamPlusPlusSpeaker.swift`.

Upstream Git tree identities:

- `Sources/AudioCommon`: `ad5ac6a4ff70513d87fffea7f13ddffe09e64853`
- `Sources/MLXCommon`: `db4d24f91978c4b3f2d4ce96f65dcbe2ae49c566`
- `Sources/CosyVoiceTTS`: `2ce21f533776af9f6ed8c5c42b59164baa5d49b8`
- `Sources/Qwen3TTS`: `4b9f1604f7746ef91a34402c9955a7ceba12d717`
- `LICENSE`: `8340a9931225e516119c90f53e09abfe8413dd6a`

The reduced `Package.swift` pins the already-audited MLX Swift 0.31.6 and Swift
Transformers 1.3.3 resolutions and intentionally omits unrelated speech server,
ASR, UI, benchmark, and demo targets.

## Local patch

Swift's `Float16` is explicitly unavailable for macOS x86_64. Upstream
`CamPlusPlusSpeaker` uses it for an optional CoreML voice-cloning component, which
AudiobookMaker does not expose and must never initialize on Intel/Rosetta. The
arm64 implementation body remains byte-for-byte upstream. The x86_64 branch provides
the same public type surface but returns a stable local unsupported error, allowing
the existing universal App and Kokoro path to compile without enabling MLX.
The exact source delta is retained as
`PATCHES/0001-campp-intel-compile-stub.patch`.
