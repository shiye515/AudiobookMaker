# AudiobookMaker Apple Silicon Edition

> Final marketing version and the retention period for the last Universal 2 build require maintainer approval before publication.

## Breaking changes

- New builds support only native Apple Silicon (`arm64`) on macOS 26 or later.
- Intel Macs, Rosetta, and Universal 2 packages are no longer supported.
- The previous CPU/ONNX model path has been removed from the catalog, runtime, bundle, licenses, and supply chain.

## Supported voices

- Apple system speech is available immediately and requires no download.
- CosyVoice3 and Qwen3-TTS are downloaded only after explicit user action and run locally through speech-swift, MLX Swift, and Metal.
- Model weights are not included in the App bundle.

## Upgrade behavior

- A removed default model is reset to Apple system speech and its saved voice is cleared.
- Removed installation records, download resume data, and safely validated managed model directories are cleaned up.
- Queued, running, paused, or interrupted jobs tied to a removed model retain book metadata but are marked as requiring restart.
- Restart deletes the old checkpoints before a new snapshot is created with the currently selected supported model. Cross-model checkpoint reuse is prohibited.
- Completed and exported audiobooks are not modified.

## Release verification

The candidate must pass unit/UI and real-model acceptance, create an arm64-only signed/notarized archive, contain no model weights or removed runtime code, and pass the fixed-device performance baseline described in `docs/apple-silicon-performance.md`.
