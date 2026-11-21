import Foundation

enum UsageBarColor: Equatable {
    case green
    case orange
    case red
    case grey
}

struct UsageBarPresentation: Equatable {
    let used: Double?
    let color: UsageBarColor
}

struct UsageBars {
    let fiveHour: UsageBarPresentation?
    let monthly: UsageBarPresentation
    let accessibilityLabel: String

    init(state: AuthenticatedUsageSessionState) {
        func presentation(for limit: UsageLimit?) -> UsageBarPresentation {
            let color: UsageBarColor
            if state.snapshot == nil || state.isStale {
                color = .grey
            } else if let limit {
                color = limit.statusColor
            } else {
                color = .grey
            }
            return UsageBarPresentation(
                used: limit.map { 1 - $0.remainingRatio },
                color: color
            )
        }

        fiveHour = state.snapshot != nil && state.snapshot?.fiveHour == nil
            ? nil
            : presentation(for: state.snapshot?.fiveHour)
        monthly = presentation(for: state.snapshot?.monthly)

        let fiveHourText = state.snapshot?.fiveHour.map {
            "5-hour limit \(UsagePresentationFormatting.percent(1 - $0.remainingRatio)) used"
        } ?? "5-hour limit unavailable"
        let monthlyText = state.snapshot?.monthly.map {
            "monthly credits \(UsagePresentationFormatting.percent(1 - $0.remainingRatio)) used"
        } ?? "monthly credits unavailable"
        let freshness: String
        if state.snapshot == nil {
            freshness = "no usage data available"
        } else {
            freshness = state.isStale ? "data stale" : "data up to date"
        }
        accessibilityLabel = [fiveHourText, monthlyText, freshness].joined(separator: "; ")
            + (state.isRefreshing ? "; refresh in progress" : "")
    }
}

struct UsageLimitPresentation: Equatable {
    let title: String
    let usedText: String
    let relativeResetText: String?
    let exactResetText: String?
}

struct UsagePopover {
    let fiveHour: UsageLimitPresentation
    let monthly: UsageLimitPresentation
    let lastSuccessfulUpdateText: String
    let statusText: String
    let errorReason: String?
    let authenticationInstructions = "Sign in with Kimi in your default browser."
    let isRefreshing: Bool

    init(state: AuthenticatedUsageSessionState, now: Date = Date(), calendar: Calendar = .current) {
        func limit(_ value: UsageLimit?, title: String) -> UsageLimitPresentation {
            UsageLimitPresentation(
                title: title,
                usedText: value.map { UsagePresentationFormatting.percent(1 - $0.remainingRatio) }
                    ?? "Unavailable",
                relativeResetText: value?.resetTime.map {
                    UsagePresentationFormatting.relativeDate($0, now: now, calendar: calendar)
                },
                exactResetText: value?.resetTime.map {
                    UsagePresentationFormatting.exactDate($0, calendar: calendar)
                }
            )
        }

        fiveHour = limit(state.snapshot?.fiveHour, title: "5-hour limit")
        monthly = limit(state.snapshot?.monthly, title: "Monthly credits")
        lastSuccessfulUpdateText = state.lastSuccessfulUpdate.map {
            UsagePresentationFormatting.exactDate($0, calendar: calendar)
        } ?? "Never"
        if state.snapshot == nil {
            statusText = "No usage data"
        } else if let lastSuccessfulUpdate = state.lastSuccessfulUpdate {
            let time = UsagePresentationFormatting.time(lastSuccessfulUpdate, calendar: calendar)
            if state.isStale {
                statusText = "\(state.usageFailureReason == nil ? "Out of date" : "Update failed") · data from \(time)"
            } else {
                statusText = "Updated \(time)"
            }
        } else {
            statusText = state.isStale ? "Data may be out of date" : "Not updated yet"
        }
        errorReason = state.isStale ? state.usageFailureReason : nil
        isRefreshing = state.isRefreshing
    }
}

private enum UsagePresentationFormatting {
    static func percent(_ ratio: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: ratio))?
            .replacingOccurrences(of: "\u{00A0}", with: "") ?? "Unavailable"
    }

    static func relativeDate(_ date: Date, now: Date, calendar: Calendar) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = calendar.locale
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func exactDate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    static func time(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
