import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct AutomaticProviderPriorityTests {
    private let start = Date(timeIntervalSince1970: 10000)

    private func makeStore() -> UsageStore {
        let settings = testSettingsStore(
            suiteName: "AutomaticProviderPriorityTests", userDefaults: InMemoryUserDefaults())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        for provider in UsageProvider.allCases {
            if let metadata = ProviderRegistry.shared.metadata[provider] {
                settings.setProviderEnabled(
                    provider: provider, metadata: metadata, enabled: [.claude, .kimi].contains(provider))
            }
        }
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(
                homeDirectory: "/synthetic",
                cacheTTL: 0,
                now: { Date(timeIntervalSince1970: 10000) },
                fileExists: { _ in false },
                directoryContents: { _ in nil },
                applicationURLs: { _ in [] },
                profileAccessIssue: { _ in nil }),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    private func publish(_ percent: Double, provider: UsageProvider, after seconds: Double, store: UsageStore) {
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: percent,
                    windowMinutes: 300,
                    resetsAt: self.start.addingTimeInterval(36000),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: self.start.addingTimeInterval(seconds),
                identity: ProviderIdentitySnapshot(
                    providerID: provider.instanceID,
                    accountEmail: "fixture@example.invalid",
                    accountOrganization: nil,
                    loginMethod: nil)),
            provider: provider)
    }

    @Test func `active lower usage provider outranks idle ninety percent`() {
        let store = self.makeStore()
        self.publish(90, provider: .claude, after: 0, store: store)
        self.publish(10, provider: .kimi, after: 0, store: store)
        self.publish(20, provider: .kimi, after: 120, store: store)
        #expect(store.providerWithHighestUsage(now: self.start.addingTimeInterval(120))?.provider == .kimi)
    }

    @Test func `latest consumption follows a provider switch beyond one minute`() {
        let store = self.makeStore()
        self.publish(89, provider: .claude, after: 0, store: store)
        self.publish(10, provider: .kimi, after: 0, store: store)
        self.publish(90, provider: .claude, after: 120, store: store)
        self.publish(20, provider: .kimi, after: 240, store: store)
        #expect(store.providerWithHighestUsage(now: self.start.addingTimeInterval(240))?.provider == .kimi)
    }

    @Test func `concurrent activity ranks depletion forecast ahead of percent`() {
        let store = self.makeStore()
        self.publish(79, provider: .claude, after: 0, store: store)
        self.publish(10, provider: .kimi, after: 0, store: store)
        self.publish(80, provider: .claude, after: 120, store: store)
        self.publish(30, provider: .kimi, after: 120, store: store)
        #expect(store.providerWithHighestUsage(now: self.start.addingTimeInterval(120))?.provider == .kimi)
    }

    @Test func `concurrent activity without a rate falls back to percent`() {
        let store = self.makeStore()
        self.publish(79, provider: .claude, after: 0, store: store)
        self.publish(10, provider: .kimi, after: 0, store: store)
        self.publish(80, provider: .claude, after: 10, store: store)
        self.publish(30, provider: .kimi, after: 10, store: store)
        #expect(store.providerWithHighestUsage(now: self.start.addingTimeInterval(10))?.provider == .claude)
    }

    @Test func `unchanged refresh cannot override actual recent consumption`() {
        let store = self.makeStore()
        self.publish(90, provider: .claude, after: 0, store: store)
        self.publish(10, provider: .kimi, after: 0, store: store)
        self.publish(20, provider: .kimi, after: 120, store: store)
        self.publish(90, provider: .claude, after: 300, store: store)
        #expect(store.providerWithHighestUsage(now: self.start.addingTimeInterval(300))?.provider == .kimi)
    }

    @Test func `expired activity falls back and candidate subsets remain authoritative`() {
        let store = self.makeStore()
        self.publish(90, provider: .claude, after: 0, store: store)
        self.publish(10, provider: .kimi, after: 0, store: store)
        self.publish(20, provider: .kimi, after: 120, store: store)
        #expect(store.providerWithHighestUsage(
            candidateProviders: [.claude], now: self.start.addingTimeInterval(120))?.provider == .claude)
        #expect(store.providerWithHighestUsage(
            candidateProviders: [], now: self.start.addingTimeInterval(120)) == nil)
        #expect(store.providerWithHighestUsage(now: self.start.addingTimeInterval(1021))?.provider == .claude)
    }

    @Test func `explicit quota preference retains its selected lane`() {
        let store = self.makeStore()
        store.settings.setMenuBarMetricPreference(.primary, for: .claude)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 90, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                updatedAt: self.start), provider: .claude)
        let result = store.providerWithHighestUsage(candidateProviders: [.claude], now: self.start)
        #expect(result?.provider == .claude)
        #expect(result?.usedPercent == 10)
    }

    private func publishWithoutReset(
        _ percent: Double, after seconds: Double, resetAfter: Double? = nil, store: UsageStore)
    {
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: percent,
                    windowMinutes: 300,
                    resetsAt: resetAfter.map { self.start.addingTimeInterval($0) },
                    resetDescription: nil),
                secondary: nil,
                updatedAt: self.start.addingTimeInterval(seconds)),
            provider: .kimi)
    }

    @Test func `manual static percentage layout schedules actual activity expiry without resets`() {
        let store = self.makeStore()
        store.settings.menuBarDisplayMode = .percent
        self.publishWithoutReset(10, after: 0, store: store)
        self.publishWithoutReset(20, after: 120, store: store)
        let now = self.start.addingTimeInterval(300)
        let delay = store.automaticQuotaRefreshDelay(now: now)
        #expect(store.settings.refreshFrequency == .manual)
        #expect(delay != nil)
        #expect(abs((delay ?? 0) - 720.1) < 0.001)
        #expect(store.automaticQuotaRefreshDelay(now: self.start.addingTimeInterval(1021)) == nil)
    }

    @Test func `automatic refresh chooses the earlier reset deadline`() {
        let store = self.makeStore()
        self.publishWithoutReset(10, after: 0, resetAfter: 150, store: store)
        self.publishWithoutReset(20, after: 120, resetAfter: 150, store: store)
        let delay = store.automaticQuotaRefreshDelay(now: self.start.addingTimeInterval(120))
        #expect(abs((delay ?? 0) - 30.1) < 0.001)
        #expect(store.automaticQuotaRefreshDelay(now: self.start.addingTimeInterval(151)) == nil)
    }

    @Test func `provider configuration changes immediately invalidate recent activity`() {
        let store = self.makeStore()
        self.publish(90, provider: .claude, after: 0, store: store)
        self.publish(10, provider: .kimi, after: 0, store: store)
        self.publish(20, provider: .kimi, after: 120, store: store)
        let now = self.start.addingTimeInterval(120)
        #expect(store.providerWithHighestUsage(now: now)?.provider == .kimi)
        let scope = store.automaticQuotaAccountScope(for: .kimi)
        store.settings.kimiCookieSource = .off
        #expect(store.automaticQuotaAccountScope(for: .kimi) != scope)
        #expect(store.providerWithHighestUsage(now: now)?.provider == .claude)
    }

    @Test func `fixed latest activity cohort has the same winner for every provider order`() {
        let orders: [[UsageProvider]] = [
            [.claude, .kimi, .gemini], [.claude, .gemini, .kimi],
            [.kimi, .claude, .gemini], [.kimi, .gemini, .claude],
            [.gemini, .claude, .kimi], [.gemini, .kimi, .claude],
        ]
        for order in orders {
            let store = self.makeStore()
            if let metadata = ProviderRegistry.shared.metadata[.gemini] {
                store.settings.setProviderEnabled(provider: .gemini, metadata: metadata, enabled: true)
            }
            store.settings.setProviderOrder(order.map(\.instanceID))
            self.publish(89, provider: .claude, after: 110, store: store)
            self.publish(79, provider: .kimi, after: 160, store: store)
            self.publish(29, provider: .gemini, after: 210, store: store)
            self.publish(90, provider: .claude, after: 120, store: store)
            self.publish(80, provider: .kimi, after: 170, store: store)
            self.publish(30, provider: .gemini, after: 220, store: store)
            // Claude is outside the fixed latest cohort; Kimi outranks concurrent Gemini by percentage.
            #expect(store.providerWithHighestUsage(now: self.start.addingTimeInterval(220))?.provider == .kimi)
        }
    }

    @Test func `provider filtered scheduling ignores single quotas unrelated activity and disabled providers`() {
        let store = self.makeStore()
        let now = self.start.addingTimeInterval(120)
        self.publish(20, provider: .claude, after: 0, store: store)
        self.publishWithoutReset(10, after: 0, store: store)
        self.publishWithoutReset(20, after: 120, store: store)
        #expect(store.automaticQuotaRefreshDelay(
            now: now, providers: [.claude], observesRecentActivity: false, requiresMultipleQuotas: true) == nil)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 20,
                    windowMinutes: 300,
                    resetsAt: self.start.addingTimeInterval(150),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 60,
                    windowMinutes: 10080,
                    resetsAt: self.start.addingTimeInterval(36000),
                    resetDescription: nil),
                updatedAt: now), provider: .claude)
        let delay = store.automaticQuotaRefreshDelay(
            now: now, providers: [.claude], observesRecentActivity: false, requiresMultipleQuotas: true)
        #expect(delay != nil)
        #expect(abs((delay ?? 0) - 30.1) < 0.001)
        #expect(store.automaticQuotaRefreshDelay(
            now: now, providers: [], observesRecentActivity: false, requiresMultipleQuotas: true) == nil)
        store.settings.setMenuBarMetricPreference(.primary, for: .claude)
        #expect(store.automaticQuotaRefreshDelay(
            now: now,
            providers: [.claude],
            observesRecentActivity: false,
            requiresMultipleQuotas: true) == nil)
        #expect(store.automaticQuotaRefreshDelay(
            now: now,
            providers: [.claude],
            observesRecentActivity: false,
            requiresMultipleQuotas: true,
            usesLayoutAutomaticWindow: true) == delay)
        if let metadata = ProviderRegistry.shared.metadata[.claude] {
            store.settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: false)
        }
        #expect(store.automaticQuotaRefreshDelay(
            now: now, providers: [.claude], observesRecentActivity: false, requiresMultipleQuotas: true) == nil)
    }
}
