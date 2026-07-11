import Foundation
import XCTest
@testable import TokenScopeCore

final class UsageDataStatusTests: XCTestCase {
    func testIdleWithSnapshotResolvesCached() {
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let status = UsageDataStatus.resolve(
            snapshot: makeSnapshot(updatedAt: updatedAt),
            refreshState: .idle,
            errorMessage: nil
        )

        XCTAssertEqual(status, .cached(updatedAt: updatedAt))
    }

    func testIdleWithoutSnapshotResolvesUnavailable() {
        XCTAssertEqual(
            UsageDataStatus.resolve(snapshot: nil, refreshState: .idle, errorMessage: nil),
            .unavailable
        )
    }

    func testLoadingWithSnapshotCarriesPreviousUpdate() {
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let status = UsageDataStatus.resolve(
            snapshot: makeSnapshot(updatedAt: updatedAt),
            refreshState: .loading,
            errorMessage: nil
        )

        XCTAssertEqual(status, .refreshing(previousUpdate: updatedAt))
    }

    func testLoadingWithoutSnapshotCarriesNoPreviousUpdate() {
        XCTAssertEqual(
            UsageDataStatus.resolve(snapshot: nil, refreshState: .loading, errorMessage: nil),
            .refreshing(previousUpdate: nil)
        )
    }

    func testLoadedWithSnapshotResolvesCurrent() {
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let status = UsageDataStatus.resolve(
            snapshot: makeSnapshot(updatedAt: updatedAt),
            refreshState: .loaded,
            errorMessage: nil
        )

        XCTAssertEqual(status, .current(updatedAt: updatedAt))
    }

    func testLoadedWithoutSnapshotResolvesUnavailable() {
        XCTAssertEqual(
            UsageDataStatus.resolve(snapshot: nil, refreshState: .loaded, errorMessage: nil),
            .unavailable
        )
    }

    func testFailedWithSnapshotResolvesStaleUsingProvidedError() {
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let status = UsageDataStatus.resolve(
            snapshot: makeSnapshot(updatedAt: updatedAt),
            refreshState: .failed,
            errorMessage: "Synthetic refresh failure"
        )

        XCTAssertEqual(
            status,
            .stale(updatedAt: updatedAt, message: "Synthetic refresh failure")
        )
    }

    func testFailedWithoutSnapshotResolvesFailedUsingProvidedError() {
        XCTAssertEqual(
            UsageDataStatus.resolve(
                snapshot: nil,
                refreshState: .failed,
                errorMessage: "Synthetic initial failure"
            ),
            .failed(message: "Synthetic initial failure")
        )
    }

    func testFailedWithSnapshotUsesLocalizedUnknownErrorWhenErrorIsEmpty() {
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let status = UsageDataStatus.resolve(
            snapshot: makeSnapshot(updatedAt: updatedAt),
            refreshState: .failed,
            errorMessage: ""
        )

        XCTAssertEqual(
            status,
            .stale(updatedAt: updatedAt, message: CoreL10n.string("Unknown error"))
        )
    }

    func testFailedWithoutSnapshotUsesLocalizedUnknownErrorWhenErrorIsMissing() {
        XCTAssertEqual(
            UsageDataStatus.resolve(snapshot: nil, refreshState: .failed, errorMessage: nil),
            .failed(message: CoreL10n.string("Unknown error"))
        )
    }

    private func makeSnapshot(updatedAt: Date) -> ProviderUsageSnapshot {
        ProviderUsageSnapshot(
            provider: .claudeCode,
            updatedAt: updatedAt,
            sourceLabel: "Synthetic fixture"
        )
    }
}
