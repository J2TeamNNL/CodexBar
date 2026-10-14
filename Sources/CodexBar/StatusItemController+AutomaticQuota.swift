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
        // Provider-specific by design: Codex bar metrics come from its consumer projection.
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

    func menuBarSnapshotUpdatingAutoTooltip(
        provider: UsageProvider,
        button: NSStatusBarButton,
        now: Date = .init()) -> UsageSnapshot?
    {
        let snapshot = self.store.menuBarSnapshot(for: provider.instanceID)
        button.toolTip = self.menuBarRendersAutomaticMetric(provider: provider, snapshot: snapshot, now: now)
            ? self.store.automaticQuotaExplanation(provider: provider, snapshot: snapshot, now: now)
            : nil
        return snapshot
    }

    private func menuBarRendersAutomaticMetric(provider: UsageProvider, snapshot: UsageSnapshot?, now: Date) -> Bool {
        guard self.settings.menuBarShowsBrandIconWithPercent else { return false }
        let resolution = self.renderedMenuBarLayoutResolution(for: provider)
        if resolution.usesLegacyRendering {
            guard self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot) == .automatic,
                  self.legacyMenuBarBalanceText(provider: provider, snapshot: snapshot, now: now) == nil,
                  let automaticWindow = self.menuBarMetricWindow(for: provider, snapshot: snapshot, now: now)
            else { return false }
            if provider == .kiro {
                return self.legacyKiroRendersAutomaticMetric(
                    snapshot: snapshot,
                    window: automaticWindow,
                    now: now)
            }
            return true
        }

        let data = self.menuBarLayoutRenderData(provider: provider, snapshot: snapshot, warningFlash: false, now: now)
        return MenuBarLayoutRenderer.renderedTokens(
            layout: resolution.layout,
            data: data,
            conditionals: self.settings.menuBarLayoutConditionals,
            now: now).contains { token in
            switch token {
            case .percent(window: .automatic), .pace(window: .automatic), .progressBar(window: .automatic): true
            default: token.resetWindow == .automatic
            }
        }
    }

    private func legacyKiroRendersAutomaticMetric(
        snapshot: UsageSnapshot?,
        window: RateWindow,
        now: Date) -> Bool
    {
        guard let snapshot, snapshot.primary == window else { return false }
        let kiroMode = self.settings.kiroMenuBarDisplayMode
        guard let text = Self.kiroDisplayText(
            snapshot: snapshot,
            mode: kiroMode,
            showUsed: self.settings.usageBarsShowUsed)
        else { return false }
        let showUsed = kiroMode == .percentLeft ? false : self.settings.usageBarsShowUsed
        let percentText = MenuBarDisplayText.percentText(window: snapshot.primary, showUsed: showUsed)
        if let percentText, text == percentText || text.hasSuffix(" · \(percentText)") {
            return true
        }
        guard self.settings.menuBarDisplayMode == .pace || self.settings.menuBarDisplayMode == .both else {
            return false
        }
        return self.store.menuBarLayoutPaceText(
            provider: .kiro,
            window: window,
            dataConfidence: snapshot.dataConfidence,
            now: now) != nil
    }
}
