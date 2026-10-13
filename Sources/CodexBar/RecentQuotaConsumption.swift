import CodexBarCore
import Foundation

/// Transient observations of measured quota increases, bounded to the current lanes of each provider.
struct RecentQuotaConsumption {
    private struct Sample {
        let window: RateWindow
        let consumedAt: Date
        let percentPerSecond: Double?
    }

    private struct State {
        let identity: [String?]
        let accountScope: String?
        var samples: [String: Sample]
    }

    private var states: [ProviderInstanceID: State] = [:]
    private static let freshness: TimeInterval = 15 * 60

    mutating func observe(
        provider: ProviderInstanceID,
        previous: UsageSnapshot?,
        current: UsageSnapshot?,
        accountScope: String? = nil)
    {
        guard let current else {
            self.states.removeValue(forKey: provider)
            return
        }
        let identity = Self.identity(current, provider: provider)
        let priorState = self.states[provider]
        var samples = priorState?.identity == identity && priorState?.accountScope == accountScope
            ? priorState?.samples ?? [:] : [:]
        let currentLanes = Self.lanes(current)
        samples = samples.filter { currentLanes[$0.key] != nil }
        for (lane, window) in currentLanes {
            guard let previous, Self.identity(previous, provider: provider) == identity,
                  priorState == nil || priorState?.accountScope == accountScope,
                  let old = Self.lanes(previous)[lane], Self.samePeriod(old, window),
                  window.usedPercent >= old.usedPercent
            else {
                samples.removeValue(forKey: lane)
                continue
            }
            let interval = current.updatedAt.timeIntervalSince(previous.updatedAt)
            if interval == 0, old == window { continue }
            guard interval > 0, interval <= Self.freshness else {
                samples.removeValue(forKey: lane)
                continue
            }
            if window.usedPercent > old.usedPercent {
                let rate = interval >= 60 ? (window.usedPercent - old.usedPercent) / interval : nil
                samples[lane] = Sample(window: window, consumedAt: current.updatedAt, percentPerSecond: rate)
            }
        }
        self.states[provider] = State(identity: identity, accountScope: accountScope, samples: samples)
    }

    func lastConsumedAt(
        provider: ProviderInstanceID,
        snapshot: UsageSnapshot,
        now: Date,
        accountScope: String? = nil) -> Date?
    {
        self.matchingSamples(provider: provider, snapshot: snapshot, now: now, accountScope: accountScope)
            .map(\.consumedAt).max()
    }

    func etaSeconds(
        provider: ProviderInstanceID,
        snapshot: UsageSnapshot,
        window: RateWindow,
        now: Date,
        accountScope: String? = nil) -> TimeInterval?
    {
        // RateWindow has no lane identifier. Equal lane values can hide different growth rates.
        let matchingLanes = Self.lanes(snapshot).values.filter { $0 == window }
        guard Self.valid(window), matchingLanes.count == 1,
              let sample = self.matchingSamples(
                  provider: provider, snapshot: snapshot, now: now, accountScope: accountScope)
                  .first(where: { $0.window == window }),
                  let rate = sample.percentPerSecond, rate.isFinite, rate > 0
        else { return nil }
        let eta = max(0, 100 - window.usedPercent) / rate
        return eta.isFinite ? eta : nil
    }

    private func matchingSamples(
        provider: ProviderInstanceID,
        snapshot: UsageSnapshot,
        now: Date,
        accountScope: String?) -> [Sample]
    {
        guard let state = self.states[provider], state.identity == Self.identity(snapshot, provider: provider),
              state.accountScope == accountScope,
              now.timeIntervalSince(snapshot.updatedAt) >= 0,
              now.timeIntervalSince(snapshot.updatedAt) <= Self.freshness
        else { return [] }
        let lanes = Self.lanes(snapshot)
        return state.samples.compactMap { lane, sample in
            guard let window = lanes[lane], Self.samePeriod(window, sample.window),
                  window.usedPercent == sample.window.usedPercent,
                  now.timeIntervalSince(sample.consumedAt) >= 0,
                  now.timeIntervalSince(sample.consumedAt) <= Self.freshness,
                  window.resetsAt.map({ $0 > now }) ?? true
            else { return nil }
            return sample
        }
    }

    private static func identity(_ snapshot: UsageSnapshot, provider: ProviderInstanceID) -> [String?] {
        let identity = snapshot.identity(for: provider)
        return [
            identity?.accountID,
            identity?.accountEmail,
            identity?.accountOrganization,
            identity?.loginMethod,
            identity?.widgetAccountOwnerID,
        ]
    }

    private static func valid(_ window: RateWindow) -> Bool {
        !window.isSyntheticPlaceholder && window.usedPercent.isFinite && window.usedPercent >= 0 &&
            (window.windowMinutes.map { $0 > 0 } ?? true) &&
            (window.resetsAt.map(\.timeIntervalSince1970.isFinite) ?? true)
    }

    private static func samePeriod(_ lhs: RateWindow, _ rhs: RateWindow) -> Bool {
        lhs.windowMinutes == rhs.windowMinutes && lhs.resetsAt == rhs.resetsAt
    }

    private static func lanes(_ snapshot: UsageSnapshot) -> [String: RateWindow] {
        var lanes: [String: RateWindow] = [:]
        for (key, window) in [
            ("primary", snapshot.primary),
            ("secondary", snapshot.secondary),
            ("tertiary", snapshot.tertiary),
        ] {
            if let window, Self.valid(window) { lanes[key] = window }
        }
        for named in snapshot.extraRateWindows ?? [] where named.usageKnown && Self.valid(named.window) {
            lanes["named:\(named.id)"] = named.window
        }
        return lanes
    }
}
