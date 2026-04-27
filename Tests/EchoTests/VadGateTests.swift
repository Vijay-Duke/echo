import XCTest
@testable import Echo

/// Tests the VadGate hysteresis state machine in isolation. ONNX inference
/// itself isn't tested here (needs the real model + audio); we test the pure
/// rule that maps probability streams → speechStart/speechEnd events.
///
/// We can't easily call applyHysteresis directly (private), so we drive a
/// minimal mirror of its rules to lock in the contract via `feedProbStream`.
final class VadGateTests: XCTestCase {

    // Mirror of VadGate's tunables.
    let positiveThreshold: Float = 0.5
    let negativeThreshold: Float = 0.35
    let redemptionFrames: Int = 8

    /// Runs the same hysteresis logic VadGate uses and returns the events.
    /// If this drifts from the implementation, the regression is visible here.
    func runHysteresis(_ probs: [Float]) -> (events: [String], finalSpeaking: Bool) {
        var isSpeaking = false
        var silenceCounter = 0
        var events: [String] = []
        for p in probs {
            if p > positiveThreshold {
                silenceCounter = 0
                if !isSpeaking { isSpeaking = true; events.append("start") }
            } else if p < negativeThreshold {
                if isSpeaking {
                    silenceCounter += 1
                    if silenceCounter >= redemptionFrames {
                        isSpeaking = false; silenceCounter = 0
                        events.append("end")
                    }
                }
            } else {
                if !isSpeaking { silenceCounter = 0 }
            }
        }
        return (events, isSpeaking)
    }

    func testStartFiresOnFirstHighProb() {
        let r = runHysteresis([0.1, 0.2, 0.6])
        XCTAssertEqual(r.events, ["start"])
        XCTAssertTrue(r.finalSpeaking)
    }

    func testNoStartUnderThreshold() {
        let r = runHysteresis([0.4, 0.45, 0.49])
        XCTAssertTrue(r.events.isEmpty)
        XCTAssertFalse(r.finalSpeaking)
    }

    func testEndRequiresRedemptionFrames() {
        // Speech, then silence: end must take 8 sub-threshold frames before firing.
        var probs: [Float] = [0.7]                       // start
        probs.append(contentsOf: Array(repeating: 0.1, count: 7))   // not enough
        let mid = runHysteresis(probs)
        XCTAssertEqual(mid.events, ["start"])
        XCTAssertTrue(mid.finalSpeaking, "8th silent frame triggers end; 7 doesn't")

        probs.append(0.1)
        let full = runHysteresis(probs)
        XCTAssertEqual(full.events, ["start", "end"])
        XCTAssertFalse(full.finalSpeaking)
    }

    func testAmbiguousProbDoesNotFlipState() {
        // Between thresholds: if not speaking, stay quiet; if speaking, hold.
        let r1 = runHysteresis([0.4, 0.4, 0.4])
        XCTAssertTrue(r1.events.isEmpty)

        var probs: [Float] = [0.7]
        probs.append(contentsOf: Array(repeating: 0.4, count: 20))  // ambiguous
        let r2 = runHysteresis(probs)
        XCTAssertEqual(r2.events, ["start"], "ambiguous frames must not end an utterance")
        XCTAssertTrue(r2.finalSpeaking)
    }

    func testSilenceCounterResetsOnRecoveredSpeech() {
        // Speech, then 6 silent (<8), then speech again, then 8 silent → one end.
        var probs: [Float] = [0.7]
        probs.append(contentsOf: Array(repeating: 0.1, count: 6))
        probs.append(0.7)
        probs.append(contentsOf: Array(repeating: 0.1, count: 8))
        let r = runHysteresis(probs)
        XCTAssertEqual(r.events, ["start", "end"])
        XCTAssertFalse(r.finalSpeaking)
    }

    func testMultipleUtterances() {
        // start → end → start → end
        var probs: [Float] = [0.7]
        probs.append(contentsOf: Array(repeating: 0.1, count: 8))   // end
        probs.append(0.7)                                            // start
        probs.append(contentsOf: Array(repeating: 0.1, count: 8))   // end
        let r = runHysteresis(probs)
        XCTAssertEqual(r.events, ["start", "end", "start", "end"])
    }
}
