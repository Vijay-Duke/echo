import XCTest
@testable import Echo

/// Tests for the small concurrency helpers that live alongside AudioEngine.
/// (AudioEngine itself needs real audio HW so we test only the pure pieces.)
final class AudioEngineHelpersTests: XCTestCase {

    func testReadyFlag_defaultsFalse() {
        let f = ReadyFlag()
        XCTAssertFalse(f.value)
    }

    func testReadyFlag_setReadFromMultipleThreads() {
        let f = ReadyFlag()
        let group = DispatchGroup()
        for _ in 0..<200 {
            group.enter()
            DispatchQueue.global().async { f.value = true; group.leave() }
            group.enter()
            DispatchQueue.global().async { _ = f.value; group.leave() }
        }
        group.wait()
        XCTAssertTrue(f.value)
    }

    func testRingBuffer_appendDrain() {
        let r = AudioRingBuffer()
        r.append(Data([0x01]))
        r.append(Data([0x02]))
        let out = r.drain()
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0], Data([0x01]))
        XCTAssertEqual(out[1], Data([0x02]))
        // Second drain returns empty.
        XCTAssertEqual(r.drain().count, 0)
    }

    func testRingBuffer_capsAtMax() {
        let r = AudioRingBuffer()
        // Push 150 chunks; ring caps at 100, oldest dropped.
        for i in 0..<150 {
            r.append(Data([UInt8(i & 0xFF)]))
        }
        let out = r.drain()
        XCTAssertEqual(out.count, 100, "ring buffer should cap to bound memory")
        // First retained chunk should be the 50th appended (index 50 = 0x32).
        XCTAssertEqual(out.first, Data([0x32]))
    }
}
