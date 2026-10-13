import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct RecentQuotaConsumptionTests {
    private let start = Date(timeIntervalSince1970: 10000)

    private func snapshot(
        _ percent: Double,
        after seconds: Double,
        account: String = "one",
        reset: Double = 10000,
        placeholder: Bool = false) -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: percent,
                windowMinutes: 300,
                resetsAt: self.start.addingTimeInterval(reset),
                resetDescription: nil,
                isSyntheticPlaceholder: placeholder),
            secondary: nil,
            updatedAt: self.start.addingTimeInterval(seconds),
            identity: ProviderIdentitySnapshot(
                providerID: .codex, accountEmail: account, accountOrganization: nil, loginMethod: nil))
    }

    @Test func `increases establish activity and depletion rate`() throws {
        var tracker = RecentQuotaConsumption()
        let before = self.snapshot(20, after: 0)
        let after = self.snapshot(30, after: 120)
        tracker.observe(provider: .codex, previous: before, current: after)
        #expect(tracker.lastConsumedAt(provider: .codex, snapshot: after, now: after.updatedAt) == after.updatedAt)
        #expect(try tracker.etaSeconds(
            provider: .codex,
            snapshot: after,
            window: #require(after.primary),
            now: after.updatedAt) == 840)
        let unchanged = self.snapshot(30, after: 240)
        tracker.observe(provider: .codex, previous: after, current: unchanged)
        #expect(tracker.lastConsumedAt(provider: .codex, snapshot: unchanged, now: unchanged.updatedAt) == after
            .updatedAt)
        #expect(tracker.lastConsumedAt(
            provider: .codex, snapshot: unchanged, now: self.start.addingTimeInterval(1021)) == nil)
    }

    @Test func `fast increase establishes activity without a rate`() throws {
        var tracker = RecentQuotaConsumption()
        let after = self.snapshot(30, after: 10)
        tracker.observe(provider: .codex, previous: self.snapshot(20, after: 0), current: after)
        #expect(tracker.lastConsumedAt(provider: .codex, snapshot: after, now: after.updatedAt) != nil)
        #expect(try tracker.etaSeconds(
            provider: .codex,
            snapshot: after,
            window: #require(after.primary),
            now: after.updatedAt) == nil)
    }

    @Test func `reset account decrease invalid values and long gaps do not establish activity`() {
        let before = self.snapshot(20, after: 0)
        for after in [
            self.snapshot(30, after: 120, account: "two"),
            self.snapshot(30, after: 120, reset: 20000),
            self.snapshot(10, after: 120),
            self.snapshot(.infinity, after: 120),
            self.snapshot(30, after: 901),
            self.snapshot(30, after: 120, placeholder: true),
        ] {
            var tracker = RecentQuotaConsumption()
            tracker.observe(provider: .codex, previous: before, current: after)
            #expect(tracker.lastConsumedAt(provider: .codex, snapshot: after, now: after.updatedAt) == nil)
        }
    }

    @Test func `account scope and snapshot removal invalidate activity`() {
        var tracker = RecentQuotaConsumption()
        let before = self.snapshot(20, after: 0)
        let after = self.snapshot(30, after: 120)
        tracker.observe(provider: .codex, previous: before, current: after, accountScope: "saved-one")
        #expect(tracker.lastConsumedAt(
            provider: .codex, snapshot: after, now: after.updatedAt, accountScope: "saved-two") == nil)
        tracker.observe(provider: .codex, previous: after, current: nil, accountScope: "saved-one")
        #expect(tracker.lastConsumedAt(
            provider: .codex, snapshot: after, now: after.updatedAt, accountScope: "saved-one") == nil)
    }

    @Test func `decreases and resets clear an existing consumption record`() {
        for next in [self.snapshot(25, after: 240), self.snapshot(40, after: 240, reset: 20000)] {
            var tracker = RecentQuotaConsumption()
            let consumed = self.snapshot(30, after: 120)
            tracker.observe(provider: .codex, previous: self.snapshot(20, after: 0), current: consumed)
            tracker.observe(provider: .codex, previous: consumed, current: next)
            #expect(tracker.lastConsumedAt(provider: .codex, snapshot: next, now: next.updatedAt) == nil)
        }
    }

    @Test func `unrelated dictionary observations do not refresh or remove activity`() throws {
        var tracker = RecentQuotaConsumption()
        let consumed = self.snapshot(30, after: 120)
        tracker.observe(provider: .codex, previous: self.snapshot(20, after: 0), current: consumed)
        tracker.observe(provider: .codex, previous: consumed, current: consumed)
        #expect(tracker.lastConsumedAt(
            provider: .codex, snapshot: consumed, now: consumed.updatedAt) == consumed.updatedAt)
        let mismatched = self.snapshot(40, after: 120)
        #expect(try tracker.etaSeconds(
            provider: .codex, snapshot: consumed, window: #require(mismatched.primary), now: consumed.updatedAt) ==
            nil)
    }

    @Test func `identical lane values do not select an arbitrary consumption rate`() throws {
        var tracker = RecentQuotaConsumption()
        let primary = self.snapshot(20, after: 0)
        let secondary = self.snapshot(25, after: 0)
        let current = self.snapshot(30, after: 120)
        let before = UsageSnapshot(primary: primary.primary, secondary: secondary.primary, updatedAt: primary.updatedAt)
        let after = UsageSnapshot(primary: current.primary, secondary: current.primary, updatedAt: current.updatedAt)
        tracker.observe(provider: .codex, previous: before, current: after)
        #expect(try tracker.etaSeconds(
            provider: .codex, snapshot: after, window: #require(after.primary), now: after.updatedAt) == nil)
    }
}
