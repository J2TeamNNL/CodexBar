import CodexBarCore
import Foundation

extension UsageStore {
    func automaticQuotaAccountScope(for instanceID: ProviderInstanceID) -> String {
        let account = instanceID.firstPartyProvider.flatMap {
            self.settings.effectiveSelectedTokenAccount(for: $0)?.id.uuidString
        } ?? "ambient"
        return "\(self.settings.providerConfigRevision(forInstanceID: instanceID)):\(account)"
    }

    /// Reevaluate time-dependent selection even with manual refresh and a static percentage layout.
    func automaticQuotaRefreshDelay(
        now: Date,
        providers: [UsageProvider]? = nil,
        observesRecentActivity: Bool = true,
        requiresMultipleQuotas: Bool = false,
        usesLayoutAutomaticWindow: Bool = false) -> TimeInterval?
    {
        var delays: [TimeInterval] = []
        for instanceID in self.enabledProvidersForDisplay() {
            guard let provider = instanceID.firstPartyProvider,
                  providers?.contains(provider) ?? true,
                  let snapshot = self.menuBarSnapshot(for: instanceID)
            else { continue }
            if observesRecentActivity, let activity = self.recentQuotaConsumption.lastConsumedAt(
                provider: instanceID,
                snapshot: snapshot,
                now: now,
                accountScope: self.automaticQuotaAccountScope(for: provider.instanceID))
            {
                delays.append(max(0.1, activity.addingTimeInterval(15 * 60).timeIntervalSince(now) + 0.1))
            }
            // Stored Auto tokens are independent of the legacy metric picker.
            guard usesLayoutAutomaticWindow
                || self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot) == .automatic
            else { continue }
            let candidates = MenuBarMetricWindowResolver.automaticCandidates(
                provider: provider,
                snapshot: snapshot,
                prioritizesExhaustedQuotas: self.settings.antigravityPrioritizeExhaustedQuotas,
                now: now)
            guard !requiresMultipleQuotas || candidates.count > 1 else { continue }
            for reset in candidates.compactMap(\.resetsAt) where reset > now {
                delays.append(min(60, reset.timeIntervalSince(now) + 0.1))
            }
        }
        return delays.min()
    }

    func automaticQuotaSelection(provider: UsageProvider, snapshot: UsageSnapshot, now: Date = Date())
        -> AutomaticQuotaSelection.Selection?
    {
        let candidates: [RateWindow]
        if provider == .codex {
            let projection = self.codexConsumerProjection(surface: .menuBar, snapshotOverride: snapshot, now: now)
            let quotaLanes = projection.displayedRateLanes(showOptionalCreditsAndExtraUsage: false)
            let lanes = quotaLanes.isEmpty ? projection.visibleRateLanes : quotaLanes
            candidates = lanes.compactMap { lane in
                guard projection.menuBarSelectableRateWindow(for: lane) != nil else { return nil }
                return projection.sourceRateWindow(for: lane)
            }
        } else {
            candidates = MenuBarMetricWindowResolver.automaticCandidates(
                provider: provider,
                snapshot: snapshot,
                prioritizesExhaustedQuotas: self.settings.antigravityPrioritizeExhaustedQuotas,
                now: now)
        }
        return AutomaticQuotaSelection.select(windows: candidates, now: now) { window in
            guard ProviderDescriptorRegistry.descriptor(for: provider).pace
                .allowsPace(dataConfidence: snapshot.dataConfidence) else { return nil }
            if let seconds = self.recentQuotaConsumption.etaSeconds(
                provider: provider.instanceID,
                snapshot: snapshot,
                window: window,
                now: now,
                accountScope: self.automaticQuotaAccountScope(for: provider.instanceID))
            {
                return .init(seconds: seconds, isRecent: true)
            }
            return self.weeklyPace(
                provider: provider, window: window, dataConfidence: snapshot.dataConfidence, now: now)
                .flatMap(\.etaSeconds).map { .init(seconds: $0, isRecent: false) }
        }
    }

    func automaticQuotaExplanation(provider: UsageProvider, snapshot: UsageSnapshot?, now: Date = Date()) -> String? {
        guard let snapshot,
              self.settings.menuBarMetricPreference(for: provider, snapshot: snapshot) == .automatic,
              let selection = self.automaticQuotaSelection(provider: provider, snapshot: snapshot, now: now)
        else { return nil }
        let window = selection.window
        let title: String
        if provider == .codex {
            let projection = self.codexConsumerProjection(surface: .menuBar, snapshotOverride: snapshot, now: now)
            let lane = projection.visibleRateLanes.first { projection.sourceRateWindow(for: $0) == window } ?? .session
            title = CodexConsumerProjection.rateTitle(
                lane: lane, windowMinutes: window.windowMinutes, sessionLabel: "Session", weeklyLabel: "Weekly")
        } else if let named = snapshot.extraRateWindows?.first(where: { $0.window == window }) {
            title = named.title
        } else {
            let metadata = ProviderDescriptorRegistry.descriptor(for: provider).metadata
            let labels = ProviderDescriptorRegistry.descriptor(for: provider).presentation.rateWindowLabels(
                metadata: metadata, snapshot: snapshot, now: now)
            title = window == snapshot.secondary ? labels.secondary
                : window == snapshot.tertiary ? labels.tertiary : labels.primary
        }
        let reason = selection.explanation(title: L(title))
        if self.settings.unifiedIconSource == .highestUsage,
           self.recentQuotaConsumption.lastConsumedAt(
               provider: provider.instanceID,
               snapshot: snapshot,
               now: now,
               accountScope: self.automaticQuotaAccountScope(for: provider.instanceID)) != nil
        {
            return L("Recent usage detected.") + "\n" + reason
        }
        return reason
    }
}
