import CodexBarCore
import Foundation

/// Snapshot-only ordering shared by Auto windows and the unified highest-usage icon.
enum AutomaticQuotaSelection {
    struct Selection {
        let window: RateWindow
        let eta: TimeInterval?
    }

    static func select(
        windows: [RateWindow],
        provider: UsageProvider,
        now: Date,
        dataConfidence: UsageDataConfidence = .unknown) -> Selection?
    {
        windows.compactMap {
            self.selection(window: $0, provider: provider, now: now, dataConfidence: dataConfidence)
        }.reduce(nil) { best, candidate in
            guard let best else { return candidate }
            return self.precedes(best, candidate) ? candidate : best
        }
    }

    static func selection(
        window: RateWindow,
        provider: UsageProvider,
        now: Date,
        dataConfidence: UsageDataConfidence) -> Selection?
    {
        guard !window.isSyntheticPlaceholder, window.usedPercent.isFinite, window.usedPercent >= 0 else { return nil }
        let capability = ProviderDescriptorRegistry.descriptor(for: provider).pace
        var eta: TimeInterval?
        if capability.allowsPace(dataConfidence: dataConfidence), window.windowMinutes != nil,
           let pace = UsagePace.weekly(window: capability.resolvedResetWindowForPace(window), now: now),
           pace.expectedUsedPercent >= 3, let seconds = pace.etaSeconds, seconds.isFinite, seconds > 0,
           let reset = window.resetsAt, seconds < reset.timeIntervalSince(now)
        {
            eta = seconds
        }
        return Selection(window: window, eta: eta)
    }

    static func precedes(_ lhs: Selection, _ rhs: Selection) -> Bool {
        if (lhs.window.usedPercent >= 100) != (rhs.window.usedPercent >= 100) {
            return lhs.window.usedPercent < 100
        }
        if (lhs.eta != nil) != (rhs.eta != nil) {
            return lhs.eta == nil
        }
        if let left = lhs.eta, let right = rhs.eta, left != right {
            return left > right
        }
        return lhs.window.usedPercent < rhs.window.usedPercent
    }
}
