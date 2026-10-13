import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    /// Favors observed recent consumption, then depletion risk, within the enabled candidate providers.
    /// A refresh alone is not activity. Providers that are fully rate-limited remain excluded.
    func providerWithHighestUsage(candidateProviders: [UsageProvider]? = nil, now: Date = Date())
        -> (provider: UsageProvider, usedPercent: Double)?
    {
        let candidateSet = candidateProviders.map(Set.init)
        var candidates: [(provider: UsageProvider, selection: AutomaticQuotaSelection.Selection, activity: Date?)] = []
        for instanceID in self.enabledProviders() {
            guard let provider = instanceID.firstPartyProvider,
                  candidateSet?.contains(provider) ?? true,
                  let snapshot = self.menuBarSnapshot(for: instanceID),
                  let window = self.menuBarMetricWindowForHighestUsage(
                      provider: provider,
                      snapshot: snapshot,
                      now: now),
                  window.usedPercent.isFinite,
                  !self.shouldExcludeFromHighestUsage(
                      provider: provider, snapshot: snapshot, metricPercent: window.usedPercent, now: now)
            else { continue }
            let activity = self.recentQuotaConsumption.lastConsumedAt(
                provider: instanceID,
                snapshot: snapshot,
                now: now,
                accountScope: self.automaticQuotaAccountScope(for: instanceID))
            let automatic = self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot) == .automatic
                ? self.automaticQuotaSelection(provider: provider, snapshot: snapshot, now: now) : nil
            candidates.append((provider, automatic ?? .init(window: window, forecast: nil), activity))
        }
        if let latestActivity = candidates.compactMap(\.activity).max() {
            // A fixed cohort avoids polling-order churn and pairwise, non-transitive recency comparisons.
            candidates = candidates.filter { candidate in
                candidate.activity.map { latestActivity.timeIntervalSince($0) <= 60 } ?? false
            }
        }
        let highest = candidates.reduce(nil as (
            provider: UsageProvider,
            selection: AutomaticQuotaSelection.Selection,
            activity: Date?)?)
        { best, candidate in
            guard let best else { return candidate }
            return AutomaticQuotaSelection.precedes(best.selection, candidate.selection) ? candidate : best
        }
        return highest.map { ($0.provider, $0.selection.window.usedPercent) }
    }

    private func menuBarMetricWindowForHighestUsage(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        now: Date) -> RateWindow?
    {
        let effectivePreference = self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot)
        if provider == .codex {
            return self.codexMenuBarMetricWindow(snapshot: snapshot, now: now)
        }
        if effectivePreference == .automatic {
            return self.automaticQuotaSelection(provider: provider, snapshot: snapshot, now: now)?.window
        }
        return MenuBarMetricWindowResolver.rateWindow(
            preference: effectivePreference,
            provider: provider,
            snapshot: snapshot,
            supportsAverage: self.settings.menuBarMetricSupportsAverage(for: provider),
            antigravityPrioritizeExhaustedQuotas: self.settings.antigravityPrioritizeExhaustedQuotas,
            now: now)
    }

    private func shouldExcludeFromHighestUsage(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        metricPercent: Double,
        now: Date)
        -> Bool
    {
        let effectivePreference = self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot)
        guard metricPercent >= 100 else { return false }
        // Provider-specific by design: exclusion mirrors each provider's multi-lane resolver and optional quotas.
        if provider == .codex || provider == .claude, effectivePreference == .primaryAndSecondary {
            if provider == .codex,
               self.codexConsumerProjection(
                   surface: .menuBar,
                   snapshotOverride: snapshot,
                   now: now).hasBindingWeeklyCap
            {
                return true
            }
            // A Claude spend-limit-only snapshot has no real session/weekly lanes; the metric resolves to
            // the spend-limit window, so reaching here (metricPercent >= 100) means the spend limit itself
            // is exhausted. Mirror that resolver fallback and exclude, instead of inspecting the raw 0%
            // placeholder primary that would otherwise keep it eligible.
            if provider == .claude, MenuBarMetricWindowResolver.claudeSpendLimitWindow(snapshot: snapshot) != nil {
                return true
            }
            // Ignore synthesized placeholder lanes (e.g. Claude web's null `five_hour` 0% session) so a
            // fully exhausted weekly-only account is excluded rather than kept eligible by a phantom 0%.
            let percents = [snapshot.primary, snapshot.secondary]
                .compactMap(\.self)
                .filter { !$0.isSyntheticPlaceholder }
                .map(\.usedPercent)
            guard !percents.isEmpty else { return true }
            return percents.allSatisfy { $0 >= 100 }
        }
        if provider == .antigravity, effectivePreference == .automatic {
            if self.settings.antigravityPrioritizeExhaustedQuotas {
                return MenuBarMetricWindowResolver.antigravityQuotaSummaryFamiliesAreAllBlocked(snapshot: snapshot)
            }
            let windows = Self.antigravityRenderedQuotaSummaryWindows(snapshot: snapshot)
            guard !windows.isEmpty else { return true }
            return windows.allSatisfy { $0.usedPercent >= 100 }
        }
        if provider == .copilot,
           effectivePreference == .automatic,
           let primary = snapshot.primary,
           let secondary = snapshot.secondary
        {
            // In automatic mode Copilot can have one depleted lane while another still has quota.
            return primary.usedPercent >= 100 && secondary.usedPercent >= 100
        }
        if provider == .cursor,
           effectivePreference == .automatic
        {
            let percents = [
                snapshot.primary?.usedPercent,
                snapshot.secondary?.usedPercent,
                snapshot.tertiary?.usedPercent,
            ].compactMap(\.self)
            guard !percents.isEmpty else { return true }
            return percents.allSatisfy { $0 >= 100 }
        }
        if effectivePreference == .automatic,
           MenuBarMetricWindowResolver.automaticSelectionPrioritizesExhaustedWindow(for: provider)
        {
            let percents = [
                snapshot.primary?.usedPercent,
                snapshot.secondary?.usedPercent,
                snapshot.tertiary?.usedPercent,
            ].compactMap(\.self)
            guard !percents.isEmpty else { return true }
            return percents.allSatisfy { $0 >= 100 }
        }

        return true
    }

    private nonisolated static func antigravityRenderedQuotaSummaryWindows(
        snapshot: UsageSnapshot) -> [RateWindow]
    {
        let windows = IconRemainingResolver.resolvedWindows(snapshot: snapshot, style: .antigravity)
        return [windows.primary, windows.secondary].compactMap(\.self)
    }
}
