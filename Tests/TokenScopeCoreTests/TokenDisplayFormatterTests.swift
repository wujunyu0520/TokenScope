import XCTest
@testable import TokenScopeCore

final class TokenDisplayFormatterTests: XCTestCase {
    func testFormatsTokenCountsInHundredMillions() {
        XCTAssertEqual(TokenDisplayFormatter.hundredMillions(0), "0")
        XCTAssertEqual(TokenDisplayFormatter.hundredMillions(1_000_000), "0.01亿")
        XCTAssertEqual(TokenDisplayFormatter.hundredMillions(12_345_678), "0.12亿")
        XCTAssertEqual(TokenDisplayFormatter.hundredMillions(123_456_789), "1.23亿")
        XCTAssertEqual(TokenDisplayFormatter.hundredMillions(1_234_567_890), "12.3亿")
        XCTAssertEqual(TokenDisplayFormatter.hundredMillions(12_345_678_900), "123亿")
    }

    func testFormatsSmallNonzeroCountsWithoutRoundingToZero() {
        XCTAssertEqual(TokenDisplayFormatter.hundredMillions(10_000), "0.0001亿")
        XCTAssertEqual(TokenDisplayFormatter.hundredMillions(1_000), "<0.0001亿")
    }

    func testFormatsProviderUsageSummaryInHundredMillions() {
        XCTAssertEqual(TokenDisplayFormatter.usageSummary(2_906_645_970), "29.1亿")
        XCTAssertEqual(TokenDisplayFormatter.usageSummary(16_053_650), "0.16亿")
        XCTAssertEqual(TokenDisplayFormatter.usageSummary(236_056), "0.002亿")
        XCTAssertEqual(TokenDisplayFormatter.usageSummary(28_718), "0.0003亿")
        XCTAssertEqual(TokenDisplayFormatter.usageSummary(2_878), "<0.0001亿")
        XCTAssertEqual(TokenDisplayFormatter.usageSummary(0), "0亿")
    }
}
