@testable import KimiBar
import XCTest

final class UsageBarsTests: XCTestCase {
    func testEmptyStateDoesNotFabricateEitherLimit() {
        let bars = UsageBars(state: Self.state(
            fiveHour: nil, monthly: nil, snapshotExists: false
        ))

        XCTAssertNil(bars.fiveHour?.used)
        XCTAssertNil(bars.monthly.used)
        XCTAssertEqual(bars.fiveHour?.color, .grey)
        XCTAssertEqual(bars.monthly.color, .grey)
        XCTAssertEqual(bars.accessibilityLabel, "5-hour limit unavailable; monthly credits unavailable; no usage data available")
    }

    func testBarsTrackUsedAndShareStatusColorScale() {
        let bars = UsageBars(state: Self.state(
            fiveHour: 0.5,
            monthly: 0.199_999
        ))

        XCTAssertEqual(bars.fiveHour?.used, 0.5)
        XCTAssertEqual(bars.monthly.used, 0.800_001)
        XCTAssertEqual(bars.fiveHour?.color, .green)
        XCTAssertEqual(bars.monthly.color, .red)

        let orange = UsageBars(state: Self.state(fiveHour: 0.499_999, monthly: 0.2))
        XCTAssertEqual(orange.fiveHour?.color, .orange)
        XCTAssertEqual(orange.monthly.color, .orange)
    }

    func testStaleBarsAreGreyAndKeepLastKnownLengths() throws {
        let bars = UsageBars(state: Self.state(
            fiveHour: 0.4,
            monthly: 0.7,
            isStale: true,
            usageFailureReason: "The network is offline."
        ))

        XCTAssertEqual(bars.fiveHour?.used, 0.6)
        XCTAssertEqual(try XCTUnwrap(bars.monthly.used), 0.3, accuracy: 0.000_001)
        XCTAssertEqual(bars.fiveHour?.color, .grey)
        XCTAssertEqual(bars.monthly.color, .grey)
        XCTAssertTrue(bars.accessibilityLabel.contains("data stale"))
    }

    func testMissingFiveHourLimitRendersOnlyMonthlyBarAndUnavailablePopoverRow() {
        let state = Self.state(fiveHour: nil, monthly: 0.65)

        let bars = UsageBars(state: state)
        let popover = UsagePopover(state: state, now: Self.now, calendar: Self.calendar)

        XCTAssertNil(bars.fiveHour)
        XCTAssertEqual(bars.monthly.used, 0.35)
        XCTAssertEqual(popover.fiveHour.usedText, "Unavailable")
        XCTAssertEqual(popover.monthly.usedText, "35%")
        XCTAssertTrue(bars.accessibilityLabel.contains("5-hour limit unavailable"))
        XCTAssertTrue(bars.accessibilityLabel.contains("monthly credits 35% used"))
    }

    func testPopoverRendersPercentagesRelativeAndExactLocalResetsAndLastSuccess() {
        let reset = Self.now.addingTimeInterval(2 * 60 * 60)
        let state = Self.state(
            fiveHour: 0.5,
            monthly: 0.75,
            fiveHourReset: reset,
            monthlyReset: nil,
            lastSuccessfulUpdate: Self.now
        )

        let popover = UsagePopover(state: state, now: Self.now, calendar: Self.calendar)

        XCTAssertEqual(popover.fiveHour.usedText, "50%")
        XCTAssertEqual(popover.fiveHour.relativeResetText, "in 2 hours")
        XCTAssertEqual(popover.fiveHour.exactResetText, "Jan 1, 2025 at 2:00 AM")
        XCTAssertEqual(popover.monthly.usedText, "25%")
        XCTAssertNil(popover.monthly.relativeResetText)
        XCTAssertNil(popover.monthly.exactResetText)
        XCTAssertEqual(popover.lastSuccessfulUpdateText, "Jan 1, 2025 at 12:00 AM")
        XCTAssertEqual(popover.statusText, "Updated 12:00 AM")
        XCTAssertNil(popover.errorReason)
    }

    func testStalePopoverShowsErrorReasonAndLastSuccessfulUpdate() {
        let state = Self.state(
            fiveHour: 0.4,
            monthly: 0.7,
            lastSuccessfulUpdate: Self.now,
            isStale: true,
            usageFailureReason: "The network is offline."
        )

        let popover = UsagePopover(state: state, now: Self.now, calendar: Self.calendar)

        XCTAssertEqual(popover.errorReason, "The network is offline.")
        XCTAssertEqual(popover.lastSuccessfulUpdateText, "Jan 1, 2025 at 12:00 AM")
        XCTAssertEqual(popover.statusText, "Update failed · data from 12:00 AM")
    }

    func testAuthenticationRequiredShowsNativeSignInWithoutFabricatingData() {
        let state = Self.state(
            fiveHour: nil,
            monthly: nil,
            snapshotExists: false,
            isStale: true,
            phase: .signedOut,
            usageFailureReason: "Authentication required"
        )

        let bars = UsageBars(state: state)
        let popover = UsagePopover(state: state, now: Self.now, calendar: Self.calendar)

        XCTAssertNil(bars.fiveHour?.used)
        XCTAssertNil(bars.monthly.used)
        XCTAssertEqual(popover.fiveHour.usedText, "Unavailable")
        XCTAssertEqual(popover.monthly.usedText, "Unavailable")
        XCTAssertEqual(popover.errorReason, "Authentication required")
        XCTAssertEqual(
            popover.authenticationInstructions,
            "Sign in with Kimi in your default browser."
        )
        XCTAssertEqual(popover.lastSuccessfulUpdateText, "Never")
        XCTAssertEqual(popover.statusText, "No usage data")
    }

    func testPopoverStatusDoesNotFabricateAnUpdateTime() {
        let popover = UsagePopover(state: Self.state(fiveHour: 0.5, monthly: 0.25))

        XCTAssertEqual(popover.statusText, "Not updated yet")
    }

    func testAccessibilityReportsBothLimitsFreshnessAndRefreshProgress() {
        let fresh = UsageBars(state: Self.state(fiveHour: 0.5, monthly: 0.25))
        XCTAssertEqual(
            fresh.accessibilityLabel,
            "5-hour limit 50% used; monthly credits 75% used; data up to date"
        )

        let refreshing = UsageBars(state: Self.state(
            fiveHour: 0.5,
            monthly: 0.25,
            isRefreshing: true
        ))
        XCTAssertTrue(refreshing.accessibilityLabel.contains("data up to date"))
        XCTAssertTrue(refreshing.accessibilityLabel.contains("refresh in progress"))
    }

    private static let now = Date(timeIntervalSince1970: 1_735_689_600)
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func state(
        fiveHour: Double?,
        monthly: Double?,
        snapshotExists: Bool = true,
        fiveHourReset: Date? = nil,
        monthlyReset: Date? = nil,
        lastSuccessfulUpdate: Date? = nil,
        isRefreshing: Bool = false,
        isStale: Bool = false,
        phase: AuthenticatedUsageSessionPhase = .signedIn,
        authenticationFailureReason: String? = nil,
        usageFailureReason: String? = nil
    ) -> AuthenticatedUsageSessionState {
        AuthenticatedUsageSessionState(
            phase: phase,
            snapshot: snapshotExists ? UsageSnapshot(
                fiveHour: fiveHour.map { UsageLimit(remainingRatio: $0, resetTime: fiveHourReset) },
                monthly: monthly.map { UsageLimit(remainingRatio: $0, resetTime: monthlyReset) }
            ) : nil,
            lastSuccessfulUpdate: lastSuccessfulUpdate,
            isRefreshing: isRefreshing,
            isStale: isStale,
            authenticationFailureReason: authenticationFailureReason,
            usageFailureReason: usageFailureReason,
            userCode: nil
        )
    }
}
