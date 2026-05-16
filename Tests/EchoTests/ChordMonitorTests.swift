import XCTest
import CoreGraphics
@testable import Echo

final class ChordMonitorTests: XCTestCase {

    func testDescribe_optionBacktick() {
        XCTAssertEqual(ChordMonitor.describe(modifier: .maskAlternate, keyCode: 50), "⌥`")
    }

    func testDescribe_modifiersAreOrdered() {
        // Order is fixed: ⌃ ⌥ ⇧ ⌘ regardless of how the mask was assembled.
        let mods = CGEventFlags(rawValue:
            CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue)
        XCTAssertEqual(ChordMonitor.describe(modifier: mods, keyCode: 49), "⌃⌘Space")
    }

    func testKeyName_keycodeZeroIsADistinctValidKey() {
        // Regression: keycode 0 is kVK_ANSI_A — a real key. It must never be
        // treated as "unset" / collapsed onto the backtick default (50).
        XCTAssertEqual(ChordMonitor.keyName(50), "`")
        XCTAssertNotEqual(ChordMonitor.keyName(0), ChordMonitor.keyName(50))
    }
}
