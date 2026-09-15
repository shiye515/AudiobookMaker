import Foundation
import MLX
import MLXNN
import MLXCommon
import AudioCommon

/// MLX implementation of the DeepFilterNet3 neural network.
///
/// Loads the fp32 safetensors published by ``aufklarer/DeepFilterNet3-MLX``
/// and mirrors the inference graph of the CoreML export: 2-frame lookahead
/// shift on the input features, encoder, ERB decoder, DF decoder, DF-output
/// reshape. The DSP around it (STFT, ERB features, normalization, deep
/// filtering, iSTFT) is shared with the CoreML path in ``SpeechEnhancer``.
///
/// Layout is channels-last `[B, T, F, C]` (time = conv H axis, frequency =
/// conv W axis). All GRUs run with an explicit zero initial hidden state —
/// `MLXNN.GRU`'s `hidden: nil` path skips the `r ⊙ bhn` term on the first
/// frame, so this class implements the recurrence directly.
///
/// The weight layouts and the GRU bias folding
/// (`b = bias_ih + [bias_hh_r; bias_hh_z; 0]`, `bhn = bias_hh_n`) are
/// produced by the publishing pipeline and validated against the PyTorch
/// reference to ~1e-6 (CPU stream).
final class MLXDeepFilterNet3Network {

    // ── weight bundles ──

    /// Full or grouped input conv (3×3) + optional BN-fused pointwise.
    private struct InputConv {
        let conv: MLXArray        // [O, 3, 3, I/groups]
        let convBias: MLXArray?   // erb_conv0: BN fused into the conv itself
        let pw: MLXArray?         // df_conv0: BN fused into the pointwise
        let pwBias: MLXArray?
        let groups: Int
    }

    /// Separable block: depthwise (1,3) conv + BN-fused pointwise.
    private struct SepConv {
        let dw: MLXArray          // [C, 1, 3, 1]
        let pw: MLXArray          // [C, 1, 1, C]
        let pwBias: MLXArray      // [C]
        let fstride: Int
    }

    /// Pathway block: depthwise 1×1 conv with BN fused (per-channel affine).
    private struct Pathway {
        let w: MLXArray           // [C, 1, 1, 1]
        let bias: MLXArray        // [C]
    }

    /// Transposed separable block: depthwise transposed (1,3) conv with
    /// frequency stride 2 + BN-fused pointwise. The depthwise kernel is
    /// pre-flipped along frequency for the zero-stuff formulation.
    private struct SepConvT {
        let dwFlipped: MLXArray   // [C, 1, 3, 1]
        let pw: MLXArray          // [C, 1, 1, C]
        let pwBias: MLXArray      // [C]
    }

    /// One GRU layer in the mlx convention.
    private struct GRULayer {
        let wx: MLXArray          // [3H, I]
        let wh: MLXArray          // [3H, H]
        let b: MLXArray           // [3H]
        let bhn: MLXArray         // [H]
        let hidden: Int
    }

    /// SqueezedGRU_S: grouped linear in → GRU stack → optional grouped linear out.
    private struct SqueezedGRU {
        let linearIn: MLXArray    // [g, I/g, H/g]
        let layers: [GRULayer]
        let linearOut: MLXArray?  // [g, H/g, O/g]
    }

    // ── encoder ──
    private let erbConv0: InputConv
    private let erbConv1: SepConv
    private let erbConv2: SepConv
    private let erbConv3: SepConv
    private let dfConv0: InputConv
    private let dfConv1: SepConv
    private let dfFcEmb: MLXArray            // [32, 96, 16]
    private let encEmbGru: SqueezedGRU

    // ── ERB decoder ──
    private let erbDecEmbGru: SqueezedGRU
    private let conv3p: Pathway
    private let convt3: SepConv
    private let conv2p: Pathway
    private let convt2: SepConvT
    private let conv1p: Pathway
    private let convt1: SepConvT
    private let conv0p: Pathway
    private let conv0OutW: MLXArray          // [1, 1, 3, 64]
    private let conv0OutBias: MLXArray       // [1]

    // ── DF decoder ──
    private let dfConvpConv: MLXArray        // [10, 5, 1, 32] (groups=2)
    private let dfConvpPw: MLXArray          // [10, 1, 1, 10]
    private let dfConvpPwBias: MLXArray      // [10]
    private let dfGru: SqueezedGRU
    private let dfSkip: MLXArray             // [16, 32, 16]
    private let dfOut: MLXArray              // [16, 16, 60]

    private let config: DeepFilterNet3Config

    enum MLXDeepFilterNet3Error: Error, LocalizedError {
        case missingWeight(String)
        case badShape(String, [Int])

        var errorDescription: String? {
            switch self {
            case .missingWeight(let key):
                return "MLX DeepFilterNet3 weight missing: \(key)"
            case .badShape(let key, let shape):
                return "MLX DeepFilterNet3 weight \(key) has unexpected shape \(shape)"
            }
        }
    }

    init(weights: [String: MLXArray], config: DeepFilterNet3Config) throws {
        func take(_ key: String) throws -> MLXArray {
            guard let w = weights[key] else {
                throw MLXDeepFilterNet3Error.missingWeight(key)
            }
            return w.dtype == .float32 ? w : w.asType(.float32)
        }
        func sep(_ prefix: String, fstride: Int) throws -> SepConv {
            SepConv(
                dw: try take("\(prefix).dw.weight"),
                pw: try take("\(prefix).pw.weight"),
                pwBias: try take("\(prefix).pw.bias"),
                fstride: fstride)
        }
        func pathway(_ prefix: String) throws -> Pathway {
            Pathway(w: try take("\(prefix).dw.weight"), bias: try take("\(prefix).dw.bias"))
        }
        func sepT(_ prefix: String) throws -> SepConvT {
            // Flip the depthwise transposed kernel along frequency (axis 2)
            // once at load: conv_transpose(x, w) == conv(zeroStuffed(x), flip(w)).
            let dw = try take("\(prefix).dwt.weight")
            let flipped = dw[0..., 0..., .stride(by: -1), 0...]
            return SepConvT(
                dwFlipped: flipped,
                pw: try take("\(prefix).pw.weight"),
                pwBias: try take("\(prefix).pw.bias"))
        }
        func gruLayer(_ prefix: String) throws -> GRULayer {
            let wh = try take("\(prefix).Wh")
            return GRULayer(
                wx: try take("\(prefix).Wx"),
                wh: wh,
                b: try take("\(prefix).b"),
                bhn: try take("\(prefix).bhn"),
                hidden: wh.dim(1))
        }
        func squeezedGRU(_ prefix: String, layers: Int, hasLinearOut: Bool) throws -> SqueezedGRU {
            let gruLayers: [GRULayer]
            if layers == 1 {
                gruLayers = [try gruLayer("\(prefix).gru")]
            } else {
                gruLayers = try (0..<layers).map { try gruLayer("\(prefix).gru.layers.\($0)") }
            }
            return SqueezedGRU(
                linearIn: try take("\(prefix).linear_in.weight"),
                layers: gruLayers,
                linearOut: hasLinearOut ? try take("\(prefix).linear_out.weight") : nil)
        }

        self.config = config

        self.erbConv0 = InputConv(
            conv: try take("enc.erb_conv0.conv.weight"),
            convBias: try take("enc.erb_conv0.conv.bias"),
            pw: nil, pwBias: nil, groups: 1)
        self.erbConv1 = try sep("enc.erb_conv1", fstride: 2)
        self.erbConv2 = try sep("enc.erb_conv2", fstride: 2)
        self.erbConv3 = try sep("enc.erb_conv3", fstride: 1)
        self.dfConv0 = InputConv(
            conv: try take("enc.df_conv0.conv.weight"),
            convBias: nil,
            pw: try take("enc.df_conv0.pw.weight"),
            pwBias: try take("enc.df_conv0.pw.bias"),
            groups: 2)
        self.dfConv1 = try sep("enc.df_conv1", fstride: 2)
        self.dfFcEmb = try take("enc.df_fc_emb.weight")
        self.encEmbGru = try squeezedGRU("enc.emb_gru", layers: config.encGruLayers, hasLinearOut: true)

        self.erbDecEmbGru = try squeezedGRU(
            "erb_dec.emb_gru", layers: config.erbDecGruLayers, hasLinearOut: true)
        self.conv3p = try pathway("erb_dec.conv3p")
        self.convt3 = try sep("erb_dec.convt3", fstride: 1)
        self.conv2p = try pathway("erb_dec.conv2p")
        self.convt2 = try sepT("erb_dec.convt2")
        self.conv1p = try pathway("erb_dec.conv1p")
        self.convt1 = try sepT("erb_dec.convt1")
        self.conv0p = try pathway("erb_dec.conv0p")
        self.conv0OutW = try take("erb_dec.conv0_out.conv.weight")
        self.conv0OutBias = try take("erb_dec.conv0_out.conv.bias")

        self.dfConvpConv = try take("df_dec.df_convp.conv.weight")
        self.dfConvpPw = try take("df_dec.df_convp.pw.weight")
        self.dfConvpPwBias = try take("df_dec.df_convp.pw.bias")
        self.dfGru = try squeezedGRU("df_dec.df_gru", layers: config.dfGruLayers, hasLinearOut: false)
        self.dfSkip = try take("df_dec.df_skip.weight")
        self.dfOut = try take("df_dec.df_out.weight")

        // Sanity-check a couple of load-bearing shapes so a mispublished repo
        // fails fast instead of producing garbage audio.
        guard encEmbGru.layers[0].wx.shape == [3 * config.embHidden, config.embHidden] else {
            throw MLXDeepFilterNet3Error.badShape(
                "enc.emb_gru.gru.Wx", encEmbGru.layers[0].wx.shape)
        }
        guard conv0OutW.shape == [1, 1, 3, config.convCh] else {
            throw MLXDeepFilterNet3Error.badShape("erb_dec.conv0_out.conv.weight", conv0OutW.shape)
        }
    }

    // ── building blocks ──

    private func relu(_ x: MLXArray) -> MLXArray {
        maximum(x, 0)
    }

    /// Grouped linear: x `[B, T, I]`, w `[g, I/g, H/g]` → `[B, T, H]`.
    private func groupedLinear(_ x: MLXArray, _ w: MLXArray) -> MLXArray {
        let (b, t) = (x.dim(0), x.dim(1))
        let (g, gi, gh) = (w.dim(0), w.dim(1), w.dim(2))
        let grouped = x.reshaped([b, t, g, gi])
        return einsum("btgi,gih->btgh", grouped, w).reshaped([b, t, g * gh])
    }

    /// GRU recurrence with an explicit zero initial hidden state
    /// (gate order r, z, n — identical to PyTorch).
    private func runGRULayer(_ x: MLXArray, _ layer: GRULayer) -> MLXArray {
        let hSize = layer.hidden
        let xp = matmul(x, layer.wx.T) + layer.b        // [B, T, 3H]
        let xRz = xp[0..., 0..., ..<(2 * hSize)]
        let xN = xp[0..., 0..., (2 * hSize)...]
        var h = MLXArray.zeros([x.dim(0), hSize])
        var outputs = [MLXArray]()
        outputs.reserveCapacity(x.dim(1))
        for t in 0..<x.dim(1) {
            let hp = matmul(h, layer.wh.T)              // [B, 3H]
            let rz = sigmoid(xRz[0..., t, 0...] + hp[0..., ..<(2 * hSize)])
            let r = rz[0..., ..<hSize]
            let z = rz[0..., hSize...]
            let n = tanh(xN[0..., t, 0...] + r * (hp[0..., (2 * hSize)...] + layer.bhn))
            h = (1 - z) * n + z * h
            outputs.append(h)
        }
        return stacked(outputs, axis: 1)                // [B, T, H]
    }

    private func runSqueezedGRU(_ x: MLXArray, _ gru: SqueezedGRU) -> MLXArray {
        var y = relu(groupedLinear(x, gru.linearIn))
        for layer in gru.layers {
            y = runGRULayer(y, layer)
        }
        if let linearOut = gru.linearOut {
            y = relu(groupedLinear(y, linearOut))
        }
        return y
    }

    /// pad(t=2, causal) + 3×3 conv (grouped) [+ BN-fused pointwise] + ReLU.
    private func runInputConv(_ x: MLXArray, _ block: InputConv) -> MLXArray {
        let padded2 = padded(x, widths: [IntOrPair(0), IntOrPair((2, 0)), IntOrPair(0), IntOrPair(0)])
        var y = conv2d(padded2, block.conv, stride: 1, padding: [0, 1], groups: block.groups)
        if let bias = block.convBias {
            y = y + bias
        }
        if let pw = block.pw, let pwBias = block.pwBias {
            y = conv2d(y, pw) + pwBias
        }
        return relu(y)
    }

    /// Depthwise (1,3) conv + BN-fused pointwise + ReLU.
    private func runSepConv(_ x: MLXArray, _ block: SepConv) -> MLXArray {
        let channels = x.dim(3)
        var y = conv2d(x, block.dw, stride: [1, block.fstride], padding: [0, 1], groups: channels)
        y = conv2d(y, block.pw) + block.pwBias
        return relu(y)
    }

    /// Depthwise 1×1 conv (BN-fused per-channel affine) + ReLU.
    private func runPathway(_ x: MLXArray, _ block: Pathway) -> MLXArray {
        let y = conv2d(x, block.w, groups: x.dim(3)) + block.bias
        return relu(y)
    }

    /// Depthwise transposed conv over frequency (k=3, stride 2, padding 1,
    /// output padding 1) via zero-stuffing, + BN-fused pointwise + ReLU.
    private func runSepConvT(_ x: MLXArray, _ block: SepConvT) -> MLXArray {
        let (b, t, f, c) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
        let stuffed = stacked([x, MLXArray.zeros(like: x)], axis: 3).reshaped([b, t, 2 * f, c])
        let paddedStuffed = padded(
            stuffed, widths: [IntOrPair(0), IntOrPair(0), IntOrPair((1, 1)), IntOrPair(0)])
        var y = conv2d(paddedStuffed, block.dwFlipped, groups: c)
        y = conv2d(y, block.pw) + block.pwBias
        return relu(y)
    }

    // ── inference ──

    /// Run the network.
    ///
    /// - Parameters:
    ///   - erbFeats: normalized ERB features, `[T × 32]` row-major
    ///   - specReal/specImag: normalized complex spec features, `[T × 96]`
    ///   - numFrames: `T`
    /// - Returns: `erbMask` flat `[T × 32]`, `coefs` flat in `[O, T, F, 2]`
    ///   order — the same layouts the CoreML path produces.
    func predict(
        erbFeats: [Float], specReal: [Float], specImag: [Float], numFrames: Int
    ) -> (erbMask: [Float], coefs: [Float]) {
        let erbBands = config.erbBands
        let dfBins = config.dfBins
        let la = config.convLookahead

        var featErb = MLXArray(erbFeats, [1, numFrames, erbBands, 1])
        let real = MLXArray(specReal, [1, numFrames, dfBins, 1])
        let imag = MLXArray(specImag, [1, numFrames, dfBins, 1])
        var featSpec = concatenated([real, imag], axis: 3)   // [1, T, 96, 2]

        // Lookahead shift — matches the CoreML export: drop the first `la`
        // frames, append `la` zero frames.
        if la > 0 && numFrames > la {
            let shiftWidths = [IntOrPair(0), IntOrPair((0, la)), IntOrPair(0), IntOrPair(0)]
            featErb = padded(featErb[0..., la..., 0..., 0...], widths: shiftWidths)
            featSpec = padded(featSpec[0..., la..., 0..., 0...], widths: shiftWidths)
        }

        // Encoder
        let e0 = runInputConv(featErb, erbConv0)             // [1, T, 32, 64]
        let e1 = runSepConv(e0, erbConv1)                    // [1, T, 16, 64]
        let e2 = runSepConv(e1, erbConv2)                    // [1, T, 8, 64]
        let e3 = runSepConv(e2, erbConv3)                    // [1, T, 8, 64]
        let c0 = runInputConv(featSpec, dfConv0)             // [1, T, 96, 64]
        let c1 = runSepConv(c0, dfConv1)                     // [1, T, 48, 64]

        let cemb = relu(groupedLinear(c1.reshaped([1, numFrames, -1]), dfFcEmb))
        var emb = e3.reshaped([1, numFrames, -1]) + cemb     // [1, T, 512]
        emb = runSqueezedGRU(emb, encEmbGru)

        // ERB decoder
        var d = runSqueezedGRU(emb, erbDecEmbGru)
        d = d.reshaped([1, numFrames, e3.dim(2), -1])        // [1, T, 8, 64]
        let d3 = runSepConv(runPathway(e3, conv3p) + d, convt3)
        let d2 = runSepConvT(runPathway(e2, conv2p) + d3, convt2)
        let d1 = runSepConvT(runPathway(e1, conv1p) + d2, convt1)
        var m = runPathway(e0, conv0p) + d1
        m = conv2d(m, conv0OutW, padding: [0, 1]) + conv0OutBias
        let erbMask = sigmoid(m)                             // [1, T, 32, 1]

        // DF decoder
        var c = runSqueezedGRU(emb, dfGru)                   // [1, T, 256]
        c = c + groupedLinear(emb, dfSkip)
        var cp = padded(c0, widths: [IntOrPair(0), IntOrPair((4, 0)), IntOrPair(0), IntOrPair(0)])
        cp = conv2d(cp, dfConvpConv, groups: 2)
        cp = relu(conv2d(cp, dfConvpPw) + dfConvpPwBias)     // [1, T, 96, 10]
        var cf = tanh(groupedLinear(c, dfOut))               // [1, T, 960]
        cf = cf.reshaped([1, numFrames, dfBins, config.dfOrder * 2]) + cp
        let coefs = cf
            .reshaped([1, numFrames, dfBins, config.dfOrder, 2])
            .transposed(0, 3, 1, 2, 4)                       // [1, 5, T, 96, 2]

        eval(erbMask, coefs)
        return (erbMask.asArray(Float.self), coefs.asArray(Float.self))
    }
}

// ── weight loading ──

extension DeepFilterNet3WeightLoader {

    /// Load the MLX safetensors export and auxiliary DSP data.
    ///
    /// - Parameter directory: directory containing `model.safetensors` and
    ///   `auxiliary.npz` (as published by `aufklarer/DeepFilterNet3-MLX`)
    static func loadMLX(
        from directory: URL, config: DeepFilterNet3Config
    ) throws -> (MLXDeepFilterNet3Network, AuxiliaryData) {
        let weightsURL = directory.appendingPathComponent("model.safetensors")
        let auxURL = directory.appendingPathComponent("auxiliary.npz")

        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw WeightLoadingError.noWeightsFound(directory)
        }
        guard FileManager.default.fileExists(atPath: auxURL.path) else {
            throw WeightLoadingError.missingRequiredWeight(
                "auxiliary.npz not found in \(directory.path)")
        }

        let weights = try CommonWeightLoader.loadSafetensors(url: weightsURL)
        let network = try MLXDeepFilterNet3Network(weights: weights, config: config)
        let auxData = try loadAuxiliaryData(from: auxURL)
        return (network, auxData)
    }
}
