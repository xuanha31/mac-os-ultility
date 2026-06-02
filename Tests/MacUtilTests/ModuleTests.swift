import XCTest
@testable import MonitorModule
@testable import KeyRemapModule
@testable import CleanerModule

final class ModuleTests: XCTestCase {

    func testMemoryUsedFraction() {
        let m = SystemMetrics(memoryUsed: 4_000_000_000, memoryTotal: 16_000_000_000)
        XCTAssertEqual(m.memoryUsedFraction, 0.25, accuracy: 0.0001)
    }

    func testMemoryUsedFractionZeroTotal() {
        let m = SystemMetrics(memoryUsed: 100, memoryTotal: 0)
        XCTAssertEqual(m.memoryUsedFraction, 0)
    }

    func testSwapMappingJSONContainsAllFourPairs() {
        let json = KeyRemapper.swapCommandShiftJSON
        XCTAssertTrue(json.contains("UserKeyMapping"))
        // 4 cặp → 4 entry Src.
        let count = json.components(separatedBy: "HIDKeyboardModifierMappingSrc").count - 1
        XCTAssertEqual(count, 4)
    }

    func testBuildMappingJSONFormat() {
        let json = KeyRemapper.buildMappingJSON([(.leftCommand, .leftShift)])
        // leftCommand = 0x7000000E3 = 30064771299, leftShift = 0x7000000E1 = 30064771297
        XCTAssertTrue(json.contains("\"HIDKeyboardModifierMappingSrc\":30064771299"))
        XCTAssertTrue(json.contains("\"HIDKeyboardModifierMappingDst\":30064771297"))
    }

    func testDefaultTargetsNotEmpty() {
        let cleaner = TempCleaner()
        XCTAssertFalse(cleaner.defaultTargets().isEmpty)
    }
}
