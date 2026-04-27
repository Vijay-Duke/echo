import Foundation
import AVFoundation

enum PCMConverter {
    /// Convert Float32 mono samples to Int16 little-endian Data.
    static func float32ToPCM16LE(_ floats: [Float]) -> Data {
        var data = Data(capacity: floats.count * 2)
        for f in floats {
            let clamped = max(-1.0, min(1.0, f))
            let i16 = Int16(clamped * Float(clamped < 0 ? 0x8000 : 0x7FFF))
            withUnsafeBytes(of: i16.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Convert Int16 LE Data to Float32 samples.
    static func pcm16LEToFloat32(_ data: Data) -> [Float] {
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let i16Ptr = raw.bindMemory(to: Int16.self)
            for i in 0..<count {
                out[i] = Float(Int16(littleEndian: i16Ptr[i])) / 32768.0
            }
        }
        return out
    }

    /// Linear downsample Float32 array from `srcRate` to `dstRate` (single channel).
    static func downsample(_ samples: [Float], from srcRate: Double, to dstRate: Double) -> [Float] {
        guard srcRate != dstRate else { return samples }
        let ratio = srcRate / dstRate
        let outCount = Int(Double(samples.count) / ratio)
        var out = [Float](); out.reserveCapacity(outCount)
        var i = 0.0
        while Int(i) < samples.count && out.count < outCount {
            out.append(samples[Int(i)])
            i += ratio
        }
        return out
    }
}
