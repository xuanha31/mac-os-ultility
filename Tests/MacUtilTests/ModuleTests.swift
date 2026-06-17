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

    func testHIDKeyCatalogIncludesManyKeysAndJapanese() {
        let all = KeyRemapper.HIDKey.all
        XCTAssertGreaterThan(all.count, 80, "Catalog phải đầy đủ phím, không chỉ 10 modifier")
        XCTAssertTrue(all.contains { $0.usage == 0x700000091 }, "Thiếu 英数 (LANG2)")
        XCTAssertTrue(all.contains { $0.usage == 0x700000090 }, "Thiếu かな (LANG1)")
        XCTAssertTrue(all.contains { $0.usage == 0x700000004 }, "Thiếu phím A")
    }

    func testVirtualKeyCodeLookup() {
        // 英数 = kVK_JIS_Eisu (0x66), A = kVK_ANSI_A (0x00).
        XCTAssertEqual(KeyRemapper.HIDKey.from(virtualKeyCode: 0x66)?.usage, 0x700000091)
        XCTAssertEqual(KeyRemapper.HIDKey.from(virtualKeyCode: 0x00)?.usage, 0x700000004)
        XCTAssertNil(KeyRemapper.HIDKey.from(virtualKeyCode: 0xFFFF))
    }

    func testVirtualKeyCodesAreUnique() {
        let codes = KeyRemapper.HIDKey.all.compactMap { $0.macVirtualKeyCode }
        XCTAssertEqual(codes.count, Set(codes).count, "macVirtualKeyCode phải duy nhất để bắt phím đúng")
    }

    func testCategoryPartitionsAllKeys() {
        let total = KeyRemapper.KeyCategory.allCases
            .reduce(0) { $0 + KeyRemapper.HIDKey.keys(in: $1).count }
        XCTAssertEqual(total, KeyRemapper.HIDKey.all.count, "Mỗi phím phải thuộc đúng 1 nhóm")
    }

    func testJapaneseKeyMappingJSON() {
        // capsLock (0x700000039 = 30064771129) → 英数 (0x700000091 = 30064771217)
        let eisu = KeyRemapper.HIDKey.from(virtualKeyCode: 0x66)!
        let json = KeyRemapper.buildMappingJSON([(.capsLock, eisu)])
        XCTAssertTrue(json.contains("\"HIDKeyboardModifierMappingSrc\":30064771129"))
        XCTAssertTrue(json.contains("\"HIDKeyboardModifierMappingDst\":30064771217"))
    }

    func testDefaultTargetsNotEmpty() {
        let cleaner = TempCleaner()
        XCTAssertFalse(cleaner.defaultTargets().isEmpty)
    }
}
