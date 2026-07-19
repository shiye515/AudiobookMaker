# Runtime and model distribution

AudiobookMaker ships `sherpa-onnx 1.13.2` and `ONNX Runtime 1.24.4` as signed universal dynamic XCFrameworks. Both binaries contain `x86_64` and `arm64` slices. The versions, release artifact hash and source commit are pinned in `Vendor/SherpaOnnx.version.json`; `Tools/Dependencies/fetch-sherpa-onnx.sh` reproduces the vendor artifacts.

Kokoro model weights are never included in the application bundle. After installation, the Models screen can download `kokoro-int8-multi-lang-v1_1.tar.bz2` from the signed built-in manifest. The installer:

1. accepts only HTTPS GitHub release hosts and approved redirect hosts;
2. supports progress, cancellation, retry and URLSession resume data;
3. enforces the expected compressed size and SHA-256;
4. rejects absolute paths, traversal, links and unexpected executables before extraction;
5. validates the model, voice, token, lexicon, language-data and license files;
6. atomically moves a complete version from staging into Application Support.

The runtime loads only the verified version directory below `Application Support/AudiobookMaker/Runtime/Models`. Book text and generated audio are never attached to download requests. Removing network access after installation does not affect model loading, preview or conversion.

Release verification must run `lipo -archs` for both embedded libraries, build both `ARCHS=x86_64` and `ARCHS=arm64`, inspect the app bundle for model weights, then perform signing, notarization and sandbox launch checks.

Run `Tools/Smoke/run-kokoro-host-acceptance.sh MODEL_ARCHIVE [OUTPUT_DIRECTORY]` natively on each supported architecture to record cold load, latency, RTF, memory, cancellation and the real Swift runtime smoke result. Apple Silicon evidence and the human listening gate are defined in `docs/kokoro-release-gates.md`; compiling an arm64 slice on Intel is not accepted as proof of arm64 execution.
