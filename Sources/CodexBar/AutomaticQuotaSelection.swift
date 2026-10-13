import CodexBarCore
import Foundation

/// Ranks eligible quotas; providers still own which quotas can block the current subscription.
enum AutomaticQuotaSelection {
    struct Forecast {
        let seconds: TimeInterval
        let isRecent: Bool
    }

    struct Selection {
        let window: RateWindow
        let forecast: Forecast?

        func explanation(title: String) -> String {
            if self.window.usedPercent >= 100 {
                return L("Auto: %@ is exhausted.", title)
            }
            if let forecast = self.forecast {
                let minutes = max(1, Int(ceil(forecast.seconds / 60)))
                return forecast.isRecent
                    ? L("Auto: %@ may run out first, in about %ld min at recent usage (estimated).", title, minutes)
                    : L("Auto: %@ may run out first, in about %ld min at current pace (estimated).", title, minutes)
            }
            return L(
                "Auto: %@ has the least quota remaining (%ld%% used).",
                title,
                Int(self.window.usedPercent.rounded()))
        }
    }

    static func select(
        windows: [RateWindow],
        now: Date,
        forecast: (RateWindow) -> Forecast? = { _ in nil }) -> Selection?
    {
        let candidates = windows.filter {
            !$0.isSyntheticPlaceholder && $0.usedPercent.isFinite && $0.usedPercent >= 0
        }.map { window -> Selection in
            let estimate = forecast(window).flatMap { estimate -> Forecast? in
                guard estimate.seconds.isFinite, estimate.seconds > 0,
                      let reset = window.resetsAt, estimate.seconds < reset.timeIntervalSince(now)
                else { return nil }
                return estimate
            }
            return Selection(window: window, forecast: estimate)
        }
        // Reduce keeps provider order for ties rather than letting equal readings flicker.
        return candidates.reduce(nil) { best, candidate in
            guard let best else { return candidate }
            return Self.precedes(best, candidate) ? candidate : best
        }
    }

    static func precedes(_ lhs: Selection, _ rhs: Selection) -> Bool {
        if (lhs.window.usedPercent >= 100) != (rhs.window.usedPercent >= 100) {
            return lhs.window.usedPercent < 100
        }
        if (lhs.forecast != nil) != (rhs.forecast != nil) {
            return lhs.forecast == nil
        }
        if let left = lhs.forecast, let right = rhs.forecast, left.seconds != right.seconds {
            return left.seconds > right.seconds
        }
        return lhs.window.usedPercent < rhs.window.usedPercent
    }

    static func paceForecast(provider: UsageProvider, snapshot: UsageSnapshot, window: RateWindow, now: Date)
        -> Forecast?
    {
        let capability = ProviderDescriptorRegistry.descriptor(for: provider).pace
        guard capability.allowsPace(dataConfidence: snapshot.dataConfidence), window.windowMinutes != nil,
              let pace = UsagePace.weekly(window: capability.resolvedResetWindowForPace(window), now: now),
              pace.expectedUsedPercent >= 3, let seconds = pace.etaSeconds
        else { return nil }
        return Forecast(seconds: seconds, isRecent: false)
    }
}

extension MenuBarMetricWindowResolver {
    static func automaticCandidates(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        prioritizesExhaustedQuotas: Bool = false,
        now: Date) -> [RateWindow]
    {
        let presentation = ProviderDescriptorRegistry.descriptor(for: provider).presentation
        let resolution = presentation.menuBarWindow(context: ProviderMenuBarWindowContext(
            metric: .automatic,
            snapshot: snapshot,
            supportsAverage: false,
            prioritizesExhaustedQuotas: prioritizesExhaustedQuotas,
            now: now))
        let fallback: [RateWindow] = switch resolution {
        case let .resolved(window): [window].compactMap(\.self)
        case .unhandled: [snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap(\.self)
        }
        let standard = [snapshot.primary, snapshot.secondary, snapshot.tertiary].compactMap(\.self)
        switch provider {
        // These represent ordered buckets or a balance/spend presentation, not competing rate limits.
        case .perplexity, .warp, .deepinfra, .mistral, .aixy:
            return fallback
        case .cursor:
            if let total = snapshot.primary, total.usedPercent >= 100 { return [total] }
            let extra = snapshot.extraRateWindows?.first {
                $0.id == CursorSandUsageStatus.extraWindowID && $0.usageKnown
            }?.window
            let subquotas = [snapshot.secondary, snapshot.tertiary, extra].compactMap(\.self)
            let usable = subquotas.filter { $0.usedPercent < 100 }
            if !subquotas.isEmpty, usable.isEmpty { return fallback }
            return [snapshot.primary].compactMap(\.self) + usable
        case .antigravity:
            let summary = (snapshot.extraRateWindows ?? []).filter {
                $0.usageKnown && $0.id.hasPrefix("antigravity-quota-summary-")
                    && [300, 10080].contains($0.window.windowMinutes)
            }.map(\.window)
            if prioritizesExhaustedQuotas { return fallback }
            if !summary.isEmpty {
                let usable = summary.filter { $0.usedPercent < 100 }
                return usable.isEmpty ? summary : usable
            }
            // Compact lanes may represent independent model families; keep their eligibility policy.
            return fallback
        case .kimi:
            let monthly = snapshot.extraRateWindows?.first { $0.id == "kimi-monthly" && $0.usageKnown }?.window
            return [snapshot.secondary, snapshot.primary, monthly].compactMap(\.self)
        case .claude:
            return standard.contains(where: { !$0.isSyntheticPlaceholder }) ? standard : fallback
        case .zai:
            // Monthly MCP is a separate product; never let it replace the coding-plan quota.
            return [snapshot.primary, snapshot.secondary].compactMap(\.self)
        default:
            return standard.isEmpty ? fallback : standard
        }
    }
}
