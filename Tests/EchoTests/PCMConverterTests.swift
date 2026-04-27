import XCTest
@testable import Echo

final class PCMConverterTests: XCTestCase {

    func testFloat32ToPCM16LE_roundtripPreservesAmplitude() {
        let input: [Float] = [0.0, 0.5, -0.5, 1.0, -1.0, 0.25]
        let pcm = PCMConverter.float32ToPCM16LE(input)
        let back = PCMConverter.pcm16LEToFloat32(pcm)
        XCTAssertEqual(back.count, input.count)
        for (a, b) in zip(input, back) {
            // Quantization error from int16: ~1/32768. Allow a slightly larger
            // tolerance to accommodate the asymmetric pos/neg scaling.
            XCTAssertEqual(a, b, accuracy: 0.0001)
        }
    }

    func testFloat32ToPCM16LE_clampsOutOfRange() {
        let input: [Float] = [1.5, -1.5]
        let pcm = PCMConverter.float32ToPCM16LE(input)
        let back = PCMConverter.pcm16LEToFloat32(pcm)
        XCTAssertEqual(back[0], 0.99996948, accuracy: 0.001) // ~ Int16.max / 32768
        XCTAssertEqual(back[1], -1.0, accuracy: 0.001)
    }

    func testFloat32ToPCM16LE_lengthIsTwoBytesPerSample() {
        let input = [Float](repeating: 0.0, count: 100)
        let pcm = PCMConverter.float32ToPCM16LE(input)
        XCTAssertEqual(pcm.count, 200)
    }

    func testDownsample_identityWhenRatesEqual() {
        let input: [Float] = [0.1, 0.2, 0.3, 0.4]
        let out = PCMConverter.downsample(input, from: 16000, to: 16000)
        XCTAssertEqual(out, input)
    }

    func testDownsample_halvesAtThreeToOne() {
        let input = (0..<48).map { Float($0) }
        let out = PCMConverter.downsample(input, from: 48000, to: 16000)
        XCTAssertEqual(out.count, 16)
        // Linear stride of 3 — first samples should be 0, 3, 6, 9, ...
        XCTAssertEqual(out[0], 0)
        XCTAssertEqual(out[1], 3)
        XCTAssertEqual(out[5], 15)
    }

    func testDownsample_endpointDoesNotOverflow() {
        let input = [Float](repeating: 0.5, count: 1000)
        let out = PCMConverter.downsample(input, from: 48000, to: 16000)
        XCTAssertLessThanOrEqual(out.count, 334)
        XCTAssertEqual(out.first, 0.5)
        XCTAssertEqual(out.last, 0.5)
    }
}
