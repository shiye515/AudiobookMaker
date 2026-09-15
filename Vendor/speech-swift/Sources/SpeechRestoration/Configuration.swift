import CoreML
import Foundation

/// Sidon speech-restoration model variant.
///
/// Both variants share the architecture and front-end; they differ only in the
/// predictor's weight precision on disk (the vocoder stays FP16/FP32 either
/// way). `int8` palettizes the predictor (k-means) for ~half the disk and lower
/// peak RAM at a small naturalness cost; `fp16` is the higher-fidelity default.
public enum SidonVariant: String, Sendable, CaseIterable {
    case fp16
    case int8

    /// Default HuggingFace repo id for this variant.
    ///
    /// Provisional repo (`aufklarer/Sidon-CoreML`); the variant selects a
    /// subfolder inside that repo. Override the whole id via
    /// `SpeechRestorer.fromPretrained(modelId:)` if the published layout differs.
    public var defaultModelId: String { SidonConfig.defaultModelId }

    /// Subfolder within the repo that holds this variant's two `.mlpackage` /
    /// `.mlmodelc` bundles.
    public var subfolder: String {
        switch self {
        case .fp16: return "fp16"
        case .int8: return "int8"
        }
    }
}

/// Configuration for the Sidon restoration pipeline.
///
/// The numbers here are fixed by the export (see
/// `speech-models/models/sidon/export/NOTES.md`): the CoreML predictor and
/// vocoder were traced at a **fixed** sequence length of `frames` (= 499 ≈ 10 s),
/// so the runtime chunks longer audio into `windowSamples`-sized windows.
public struct SidonConfig: Sendable {
    /// Input sample rate for the front-end / predictor (w2v-BERT is 16 kHz).
    public let inputSampleRate: Int
    /// Output sample rate produced by the DAC vocoder.
    public let outputSampleRate: Int
    /// Fixed predictor/vocoder sequence length in stacked frames.
    public let frames: Int
    /// Predictor hidden size (w2v-BERT 2.0 last_hidden_state width).
    public let hiddenSize: Int
    /// Stacked feature dimension (`80 mels * stride 2`).
    public let featureDim: Int
    /// Input samples per fixed window. `frames` stacked frames span this many
    /// 16 kHz samples (499 → 160000 = exactly 10 s).
    public let windowSamples: Int
    /// Output samples the vocoder emits per window (`audio` graph output length).
    public let outputSamplesPerWindow: Int

    /// Provisional HuggingFace repo id holding the CoreML bundles. Parameterized
    /// because the published id may change.
    public static let defaultModelId = "aufklarer/Sidon-CoreML"

    /// File / directory names inside a variant subfolder.
    public static let predictorPackageName = "Sidon-Predictor.mlpackage"
    public static let vocoderPackageName = "Sidon-Vocoder.mlpackage"
    public static let predictorCompiledName = "Sidon-Predictor.mlmodelc"
    public static let vocoderCompiledName = "Sidon-Vocoder.mlmodelc"

    /// Default configuration matching the shipped export.
    public static let `default` = SidonConfig(
        inputSampleRate: 16_000,
        outputSampleRate: 48_000,
        frames: 499,
        hiddenSize: 1024,
        featureDim: 160,
        // 499 stacked frames = 998 mel frames; the extractor yields 499 stacked
        // frames for exactly 160000 input samples (10 s @ 16 kHz).
        windowSamples: 160_000,
        // Vocoder `audio` output length for a 499-frame input (DAC ×960 minus
        // the conv-stack trim): 479014 samples ≈ 9.98 s @ 48 kHz.
        outputSamplesPerWindow: 479_014
    )
}

/// Which Core ML compute units each Sidon stage loads with.
///
/// The two stages have opposite hardware affinities, so they are placed
/// independently:
///
/// - **Predictor** (w2v-BERT 2.0, 8 layers, T = 499) is a regular transformer
///   that every backend handles well: `.all` loads in ~3 s and runs a 10 s
///   window in ~60 ms on M-series.
/// - **Vocoder** (DAC decoder, ×960 upsampling) ends in 1-D convolutions over
///   ~240k–480k-sample-wide tensors. The Neural Engine compiler must spatially
///   tile every one of those layers, which takes minutes and can fail outright
///   (observed on M5 Pro / macOS 26.5: 159 s, then `ANECCompile() FAILED`, then
///   a silent fallback ~12× slower than plain CPU). On the GPU the same graph
///   loads in ~0.3 s and runs a window in ~0.2 s, so the vocoder defaults to
///   `.cpuAndGPU`. Nothing about the export changes the tiling cost — the
///   `.mlpackage → .mlmodelc` step is ~0.1 s; the expensive part is the
///   per-device ANE program generated at `MLModel` load time, which cannot be
///   shipped precompiled.
///
/// `SPEECH_COREML_COMPUTE_UNITS` (see `CoreMLComputeUnitsResolver`) still
/// overrides both stages at load time; CI relies on that to force `cpuOnly`.
public struct SidonComputePlacement: Sendable, Equatable {
    /// Compute units for the w2v-BERT predictor.
    public var predictor: MLComputeUnits
    /// Compute units for the DAC vocoder.
    public var vocoder: MLComputeUnits

    public init(predictor: MLComputeUnits, vocoder: MLComputeUnits) {
        self.predictor = predictor
        self.vocoder = vocoder
    }

    /// Default predictor placement: let Core ML pick (Neural Engine preferred).
    public static let defaultPredictor: MLComputeUnits = .all
    /// Default vocoder placement: GPU — keeps the wide-tensor conv stack off the
    /// Neural Engine compiler (see the type docs).
    public static let defaultVocoder: MLComputeUnits = .cpuAndGPU
    /// The shipped defaults (`predictor: .all`, `vocoder: .cpuAndGPU`).
    public static let `default` = SidonComputePlacement(
        predictor: defaultPredictor, vocoder: defaultVocoder)

    /// The same units for both stages.
    public static func uniform(_ units: MLComputeUnits) -> SidonComputePlacement {
        SidonComputePlacement(predictor: units, vocoder: units)
    }

    /// Resolve a placement from the `SpeechRestorer` loader parameters: a
    /// per-stage value wins over the uniform `computeUnits`, which wins over
    /// the stage default.
    public static func resolve(
        computeUnits: MLComputeUnits?,
        predictor: MLComputeUnits?,
        vocoder: MLComputeUnits?
    ) -> SidonComputePlacement {
        SidonComputePlacement(
            predictor: predictor ?? computeUnits ?? defaultPredictor,
            vocoder: vocoder ?? computeUnits ?? defaultVocoder)
    }
}
