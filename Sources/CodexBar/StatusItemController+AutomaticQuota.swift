import AppKit
import CodexBarCore
import Foundation

extension StatusItemController {
    func menuBarAutomaticQuotaRefreshDelay(
        provider: UsageProvider,
        resolution: MenuBarLayoutResolution,
        now: Date) -> TimeInterval?
    {
        guard self.settings.menuBarShowsBrandIconWithPercent else { return nil }
        let observesAutomatic: Bool
        if resolution.usesLegacyRendering {
            observesAutomatic = self.settings.menuBarMetricPreference(for: provider) == .automatic
        } else {
            let tokens = resolution.layout.flattenedTokens(conditionals: self.settings.menuBarLayoutConditionals)
            let metrics = self.referencedConditionalMetrics(resolution: resolution)
            observesAutomatic = tokens.contains { token in
                switch token {
                case .percent(window: .automatic), .pace(window: .automatic), .progressBar(window: .automatic): true
                default: token.resetWindow == .automatic
                }
            } || !metrics.isDisjoint(with: [.automatic, .automaticPace, .automaticResetsIn])
        }
        guard observesAutomatic else { return nil }
        return self.store.automaticQuotaRefreshDelay(
            now: now,
            providers: [provider],
            observesRecentActivity: false,
            requiresMultipleQuotas: true,
            usesLayoutAutomaticWindow: true)
    }

    func menuBarMetricWindow(for provider: UsageProvider, snapshot: UsageSnapshot?, now: Date = Date()) -> RateWindow? {
        if provider == .codex {
            return self.codexMenuBarMetricWindow(snapshot: snapshot, now: now)
        }
        if let snapshot, self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot) == .automatic {
            return self.store.automaticQuotaSelection(provider: provider, snapshot: snapshot, now: now)?.window
        }
        return MenuBarMetricWindowResolver.rateWindow(
            preference: self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot),
            provider: provider,
            snapshot: snapshot,
            supportsAverage: self.settings.menuBarMetricSupportsAverage(for: provider),
            antigravityPrioritizeExhaustedQuotas: self.settings.antigravityPrioritizeExhaustedQuotas,
            now: now)
    }

    private func codexMenuBarMetricWindow(snapshot: UsageSnapshot?, now: Date) -> RateWindow? {
        guard let snapshot else { return nil }
        return self.store.codexMenuBarMetricWindow(snapshot: snapshot, now: now)
    }

    func menuBarSnapshotUpdatingAutoTooltip(provider: UsageProvider, button: NSStatusBarButton) -> UsageSnapshot? {
        let snapshot = self.store.menuBarSnapshot(for: provider.instanceID)
        button.toolTip = self.store.automaticQuotaExplanation(provider: provider, snapshot: snapshot)
        return snapshot
    }
}
