# Runtime and model distribution

AudiobookMaker ships `sherpa-onnx 1.13.2` and `ONNX Runtime 1.24.4` as signed universal dynamic XCFrameworks. Both binaries contain `x86_64` and `arm64` slices. The versions, release artifact hash and source commit are pinned in `Vendor/SherpaOnnx.version.json`; `Tools/Dependencies/fetch-sherpa-onnx.sh` reproduces the vendor artifacts.

On native Apple Silicon, the app links the audited runtime subset in `Vendor/speech-swift`: `AudioCommon`, `MLXCommon`, `CosyVoiceTTS`, and `Qwen3TTS` copied from exact speech-swift 0.0.23 revision `c1aa219bc2284239ff6917d675a3e1978c840260`. `UPSTREAM.md` records the Git tree identity of every copied subtree. The only source patch leaves arm64 unchanged and supplies an x86_64 unsupported stub for the unused CAM++ voice-cloning component whose upstream `Float16` code cannot compile for Intel macOS. The reduced local package pins MLX Swift 0.31.6 and Swift Transformers 1.3.3; remote transitive revisions remain captured by `Package.resolved`. The Release build phase `Tools/Dependencies/build-mlx-metallib.sh` compiles the required MLX kernels and fails when Xcode's Metal toolchain, kernel sources, or the resulting `mlx.metallib` are missing. These runtimes are never constructed in an Intel or Rosetta process, on an unsupported macOS release, or without a Metal device.

Kokoro model weights are never included in the application bundle. After installation, the Models screen can download `kokoro-int8-multi-lang-v1_1.tar.bz2` from the signed built-in manifest. The installer:

1. accepts only HTTPS GitHub release hosts and approved redirect hosts;
2. supports progress, cancellation, retry and URLSession resume data;
3. enforces the expected compressed size and SHA-256;
4. rejects absolute paths, traversal, links and unexpected executables before extraction;
5. validates the model, voice, token, lexicon, language-data and license files;
6. atomically moves a complete version from staging into Application Support.

The runtime loads only the verified version directory below `Application Support/AudiobookMaker/Runtime/Models`. Book text and generated audio are never attached to download requests. Removing network access after installation does not affect model loading, preview or conversion.

CosyVoice3 and Qwen3-TTS use the same interaction model as Kokoro: the user explicitly downloads a signed manifest, sees weighted multi-file progress, may cancel or repair the install, chooses a stable built-in voice, previews locally, and can make the model the default for new jobs. CosyVoice3 installs the pinned 8-bit snapshot (1,121,605,600 bytes); Qwen3-TTS installs the pinned 0.6B CustomVoice bf16 snapshot and tokenizer (2,498,418,367 bytes). The installer accepts only each manifest's exact HTTPS origin/redirect hosts, checks free space for download + staging + safety margin, hashes every artifact, writes a content receipt, and atomically commits one version. Runtime loading is offline-only and fails on a missing file instead of calling `fromPretrained()` over the network.

Both MLX models are high-memory runtimes with `recommendedConcurrency = 1`. Preview and conversion share one generation slot; switching models waits for the safe chunk boundary and releases the old session. Qwen3-TTS uses a 120-character sentence-aware secondary limit and CosyVoice3 uses 180 characters. Pause/cancel is cooperative: the current safe chunk may finish, but a late result is discarded and no output is committed. Rollback consists of hiding both signed catalog entries and keeping Apple system speech as default; existing jobs retain their locked model/version/voice and must not silently fall back.

Release verification must reproduce package resolution, verify the vendored speech-swift subtree identities/patch, run `lipo -archs` for the universal Kokoro libraries, build both universal compile-only speech-swift surfaces and native arm64 inference, verify the MLX metallib hash, inspect the app bundle for model weights/caches/reference audio, and archive a universal Release. The final archive must pass Developer ID signing, hardened-runtime verification, notarization, stapling, Gatekeeper assessment, sandbox download, offline synthesis, and the rollback switch. Intel and Rosetta runs must show speech-swift as unavailable while Kokoro remains usable.

Run `Tools/Smoke/run-kokoro-host-acceptance.sh MODEL_ARCHIVE [OUTPUT_DIRECTORY]` natively on each supported architecture to record cold load, latency, RTF, memory, cancellation and the real Swift runtime smoke result. Apple Silicon evidence and the human listening gate are defined in `docs/kokoro-release-gates.md`; compiling an arm64 slice on Intel is not accepted as proof of arm64 execution.
