import AppKit
import Network
import SwiftUI

@main
struct KimiBarApp: App {
    @StateObject private var session: AuthenticatedUsageSession
    private let wakeObserver: NSObjectProtocol
    private let networkMonitor: NWPathMonitor
    private let networkQueue = DispatchQueue(label: "com.github.pabla.KimiBar.network-monitor")

    init() {
        let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("KimiBar/usage-snapshot.json")
        let credentialManager = KimiCredentialManager()
        let fetcher = AuthenticatedUsageFetcher(
            usageAPIClient: UsageAPIClient(),
            credentialManager: credentialManager
        )
        let session = AuthenticatedUsageSession(
            manager: credentialManager,
            fetcher: fetcher,
            store: UsageSnapshotStore(fileURL: cacheURL),
            openBrowser: { NSWorkspace.shared.open($0) }
        )
        _session = StateObject(wrappedValue: session)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in session.refresh() }
        }

        let networkMonitor = NWPathMonitor()
        self.networkMonitor = networkMonitor
        var networkWasAvailable = true
        networkMonitor.pathUpdateHandler = { path in
            let networkIsAvailable = path.status == .satisfied
            // Launch already refreshes; only an offline-to-online transition needs another.
            if networkIsAvailable, !networkWasAvailable {
                Task { @MainActor in session.refresh() }
            }
            networkWasAvailable = networkIsAvailable
        }
        networkMonitor.start(queue: networkQueue)
        session.start()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(session: session)
                .onAppear { session.popoverOpened() }
        } label: {
            MenuBarIndicator(bars: UsageBars(state: session.state))
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarIndicator: View {
    let bars: UsageBars

    @MainActor var body: some View {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            func drawRing(_ bar: UsageBarPresentation, diameter: CGFloat) {
                let radius = (diameter - 3) / 2
                let center = NSPoint(x: 9, y: 9)
                let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

                NSColor.systemGray.withAlphaComponent(0.55).setStroke()
                let track = NSBezierPath(ovalIn: rect)
                track.lineWidth = 3
                track.stroke()

                if let used = bar.used, used > 0 {
                    bar.color.nsColor.setStroke()
                    let usage = NSBezierPath()
                    usage.lineWidth = 3
                    usage.lineCapStyle = .round
                    usage.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * used, clockwise: true)
                    usage.stroke()
                }
            }

            if let fiveHour = bars.fiveHour {
                drawRing(fiveHour, diameter: 18)
            }
            drawRing(bars.monthly, diameter: bars.fiveHour == nil ? 18 : 10)
            return true
        }
        return Image(nsImage: image)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(bars.accessibilityLabel)
    }
}

private struct UsageBar: View {
    let bar: UsageBarPresentation
    var width: CGFloat = 18

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.35))
            if let used = bar.used {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(nsColor: bar.color.nsColor))
                    .frame(width: width * used)
            }
        }
        .frame(width: width, height: 5)
        .clipShape(RoundedRectangle(cornerRadius: 1))
    }
}

private struct PopoverView: View {
    @ObservedObject var session: AuthenticatedUsageSession
    @FocusState private var isPopoverFocused: Bool

    var body: some View {
        let popover = UsagePopover(state: session.state)
        let bars = UsageBars(state: session.state)
        let statusDetails = [
            "Last successful update: \(popover.lastSuccessfulUpdateText)",
            popover.errorReason,
        ].compactMap { $0 }.joined(separator: "\n")
        VStack(alignment: .leading, spacing: 0) {
            UsageLimitRow(
                limit: popover.fiveHour,
                bar: bars.fiveHour,
                resetText: popover.fiveHour.relativeResetText.map { "Resets \($0)" },
                resetIsSecondary: false
            )
            .padding(.bottom, 16)
            UsageLimitRow(
                limit: popover.monthly,
                bar: bars.monthly,
                resetText: popover.monthly.exactResetText.map { "Resets \($0)" },
                resetIsSecondary: true
            )

            Divider()
                .padding(.top, 13)
                .padding(.bottom, 11)

            HStack {
                Text(popover.statusText)
                    .font(.caption)
                    .foregroundStyle(session.state.isStale ? Color.primary : Color.secondary)
                    .help(statusDetails)
                    .accessibilityLabel("\(popover.statusText). \(statusDetails)")
                Spacer(minLength: 8)
                Button(action: session.refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.borderless)
                .disabled(popover.isRefreshing || !session.state.canRefresh)
                .help("Refresh")
                .accessibilityLabel(popover.isRefreshing ? "Refreshing" : "Refresh")
            }
            switch session.state.phase {
            case .restoring:
                EmptyView()
            case .signingIn:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Finish sign-in in your browser", systemImage: "safari")
                    if let userCode = session.state.userCode {
                        Text(userCode)
                            .font(.title3.monospaced())
                            .textSelection(.enabled)
                            .accessibilityLabel("Your Kimi sign-in code is \(userCode)")
                    }
                    Button("Cancel", action: session.cancelSignIn)
                }
                .font(.callout)
                .padding(.top, 8)
            case .signedOut, .failed:
                Label(
                    session.state.authenticationFailureReason ?? popover.authenticationInstructions,
                    systemImage: "key.fill"
                )
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                Button("Sign in", action: session.signIn)
                    .padding(.top, 6)
            case .signedIn:
                if let errorMessage = session.state.authenticationFailureReason {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .padding(.top, 8)
                }
                Button("Sign out", action: session.signOut)
                    .padding(.top, 8)
            }
        }
        .padding(16)
        .frame(width: 312, alignment: .leading)
        .focusable()
        .focused($isPopoverFocused)
        .focusEffectDisabled()
        .onAppear { isPopoverFocused = true }
    }
}

private struct UsageLimitRow: View {
    let limit: UsageLimitPresentation
    let bar: UsageBarPresentation?
    let resetText: String?
    let resetIsSecondary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(limit.title)
                Spacer()
                Text(limit.usedText)
                    .fontWeight(.semibold)
                    .foregroundStyle(limit.usedText == "Unavailable" ? .secondary : .primary)
            }
            UsageBar(
                bar: bar ?? UsageBarPresentation(used: nil, color: .grey),
                width: 280
            )
            if let resetText {
                Text(resetText)
                    .font(.caption)
                    .foregroundStyle(resetIsSecondary ? Color.secondary : Color.primary)
            }
        }
    }
}

private extension UsageBarColor {
    var nsColor: NSColor {
        switch self {
        case .green: .systemGreen
        case .orange: .systemOrange
        case .red: .systemRed
        case .grey: .systemGray
        }
    }
}
