import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct AutomaticQuotaSelectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func `competing provider quotas fall back to highest measured usage`() {
        let exceptions: Set<UsageProvider> = [.perplexity, .warp, .deepinfra, .mistral, .aixy, .antigravity]
        let providers = UsageProvider.allCases.filter { !exceptions.contains($0) }
        let primary = self.window(0, name: "Session")
        let weekly = self.window(90, name: "Weekly")
        let snapshot = UsageSnapshot(primary: primary, secondary: weekly, updatedAt: self.now)
        for provider in providers {
            let selected = MenuBarMetricWindowResolver.rateWindow(
                preference: .automatic,
                provider: provider,
                snapshot: snapshot,
                supportsAverage: false,
                now: self.now)
            #expect(selected == weekly, "Failed provider: \(provider)")
        }
    }

    @Test
    func `recent faster depletion beats higher percentage and slower pace`() {
        let slow = self.window(90, resetAfter: 3600, name: "Slow")
        let fast = self.window(30, resetAfter: 3600, name: "Fast")
        let selected = AutomaticQuotaSelection.select(windows: [slow, fast], now: self.now) { window in
            .init(seconds: window == fast ? 300 : 1800, isRecent: window == fast)
        }
        #expect(selected?.window == fast)
        #expect(selected?.forecast?.isRecent == true)
        #expect(selected?.forecast?.seconds == 300)
    }

    @Test
    func `exhausted quota wins over imminent depletion`() {
        let exhausted = self.window(100, name: "Exhausted")
        let fast = self.window(20, resetAfter: 3600, name: "Fast")
        let selected = AutomaticQuotaSelection.select(windows: [fast, exhausted], now: self.now) { window in
            window == fast ? .init(seconds: 60, isRecent: true) : nil
        }
        #expect(selected?.window == exhausted)
    }

    @Test
    func `forecasts at or after reset and unknown reset cannot establish depletion risk`() {
        let higher = self.window(90, name: "Higher")
        for resetAfter: TimeInterval? in [300, 299, nil] {
            let lower = self.window(20, resetAfter: resetAfter, name: "Lower")
            let selected = AutomaticQuotaSelection.select(windows: [lower, higher], now: self.now) { window in
                window == lower ? .init(seconds: 300, isRecent: true) : nil
            }
            #expect(selected?.window == higher)
            #expect(selected?.forecast == nil)
        }
    }

    @Test
    func `invalid forecast falls back to percentage`() {
        let higher = self.window(90, resetAfter: 3600, name: "Higher")
        let lower = self.window(20, resetAfter: 3600, name: "Lower")
        for seconds in [Double.nan, .infinity, 0, -1] {
            let selected = AutomaticQuotaSelection.select(windows: [lower, higher], now: self.now) { window in
                window == lower ? .init(seconds: seconds, isRecent: true) : nil
            }
            #expect(selected?.window == higher)
        }
    }

    @Test
    func `equal percentages and equal forecasts preserve candidate order`() {
        let first = self.window(50, resetAfter: 3600, name: "First")
        let second = self.window(50, resetAfter: 3600, name: "Second")
        #expect(AutomaticQuotaSelection.select(windows: [first, second], now: self.now)?.window == first)
        let selected = AutomaticQuotaSelection.select(windows: [first, second], now: self.now) { _ in
            .init(seconds: 300, isRecent: true)
        }
        #expect(selected?.window == first)
    }

    @Test
    func `invalid percentages and placeholders are excluded`() {
        let valid = self.window(10, name: "Valid")
        let invalid = [Double.nan, .infinity, -1].map { self.window($0, name: "Invalid") }
        let placeholder = RateWindow(
            usedPercent: 100,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil,
            isSyntheticPlaceholder: true)
        let excluded = invalid + [placeholder]
        #expect(AutomaticQuotaSelection.select(windows: excluded, now: self.now) == nil)
        #expect(AutomaticQuotaSelection.select(windows: excluded + [valid], now: self.now)?.window == valid)
    }

    @Test
    func `provider over-quota readings remain exhausted rather than disappearing`() {
        let overQuota = self.window(125, name: "Over quota")
        #expect(AutomaticQuotaSelection.select(
            windows: [self.window(99, name: "Usable"), overQuota], now: self.now)?.window == overQuota)
    }

    @Test
    func `elapsed reset is not proof that the provider has restored quota`() {
        let reported = self.window(100, resetAfter: -1, name: "Reported exhausted")
        let selection = AutomaticQuotaSelection.select(windows: [reported], now: self.now) { _ in
            .init(seconds: 60, isRecent: true)
        }
        #expect(selection?.window == reported)
        #expect(selection?.forecast == nil)
    }

    @Test
    func `explicit metric choices retain their lanes`() {
        let primary = self.window(0, name: "Session")
        let secondary = self.window(90, name: "Weekly")
        let snapshot = UsageSnapshot(primary: primary, secondary: secondary, updatedAt: self.now)
        for (preference, expected) in [(MenuBarMetricPreference.primary, primary), (.secondary, secondary)] {
            #expect(MenuBarMetricWindowResolver.rateWindow(
                preference: preference,
                provider: .codex,
                snapshot: snapshot,
                supportsAverage: false,
                now: self.now) == expected)
        }
    }

    @Test
    func `ordered credit providers retain usable primary fallback`() {
        let primary = self.window(20, name: "Primary")
        let secondary = self.window(90, name: "Secondary")
        let snapshot = UsageSnapshot(primary: primary, secondary: secondary, updatedAt: self.now)
        for provider in [UsageProvider.perplexity, .warp] {
            #expect(MenuBarMetricWindowResolver.automaticCandidates(
                provider: provider, snapshot: snapshot, now: self.now) == [primary])
        }
        #expect(MenuBarMetricWindowResolver.automaticCandidates(
            provider: .mistral, snapshot: snapshot, now: self.now).isEmpty)
    }

    @Test
    func `kimi includes monthly quota only when usage is known`() {
        let primary = self.window(20, name: "Primary")
        let monthly = self.window(95, name: "Monthly")
        for known in [false, true] {
            let snapshot = UsageSnapshot(
                primary: primary,
                secondary: nil,
                extraRateWindows: [NamedRateWindow(
                    id: "kimi-monthly", title: "Monthly", window: monthly, usageKnown: known)],
                updatedAt: self.now)
            let candidates = MenuBarMetricWindowResolver.automaticCandidates(
                provider: .kimi, snapshot: snapshot, now: self.now)
            #expect(candidates.contains(monthly) == known)
            #expect(AutomaticQuotaSelection.select(windows: candidates, now: self.now)?.window
                == (known ? monthly : primary))
        }
    }

    @Test
    func `independent exhausted model pools do not replace binding subscription budgets`() {
        let primary = self.window(20, name: "Primary")
        let secondary = self.window(40, name: "Secondary")
        let separate = self.window(100, name: "Separate model pool")
        let snapshot = UsageSnapshot(primary: primary, secondary: secondary, tertiary: separate, updatedAt: self.now)
        for provider in [UsageProvider.factory, .litellm, .bifrost, .copilot, .claude] {
            #expect(MenuBarMetricWindowResolver.rateWindow(
                preference: .automatic,
                provider: provider,
                snapshot: snapshot,
                supportsAverage: false,
                now: self.now) == secondary)
        }
    }

    private func window(_ used: Double, resetAfter: TimeInterval? = nil, name: String) -> RateWindow {
        RateWindow(
            usedPercent: used,
            windowMinutes: 300,
            resetsAt: resetAfter.map { self.now.addingTimeInterval($0) },
            resetDescription: name)
    }
}
