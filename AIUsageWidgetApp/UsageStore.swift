import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshot = UsageSnapshot.empty
    @Published var isRefreshing = false

    private let localProvider = LocalUsageProvider()
    private let remoteClient = RemoteUsageClient()
    private var monitor: FileEventMonitor?
    private var refreshRequestMonitor: FileEventMonitor?
    private var lastRefreshRequestMTime: Date?
    private var pollTimer: Timer?
    private var remoteRefreshInFlight = false
    private var remoteRefreshQueued = false
    private var refreshCompletions: [() -> Void] = []

    /// Same cadence as Orca's default usage poll. Not a per-second scrape.
    private let pollInterval: TimeInterval = 15 * 60

    func start() {
        if let cached = WidgetSnapshotStore.read() {
            snapshot = cached
        }
        BackgroundAgentInstaller.installOrRefresh()
        refreshRemote()
        startFileMonitor()
        startPollTimer()
    }

    func refreshAll() {
        refreshRemote()
    }

    func forceRefreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true
        snapshot.isRefreshing = true
        WidgetSnapshotStore.write(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.widgetKind)
        let started = Date()
        refreshRemote(forceWidgetUpdate: true) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let remaining = max(0, 0.7 - Date().timeIntervalSince(started))
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
                self.isRefreshing = false
                self.snapshot.isRefreshing = false
                WidgetSnapshotStore.write(self.snapshot)
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.widgetKind)
            }
        }
    }

    func refreshWidgetAppearance() {
        WidgetSnapshotStore.write(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.widgetKind)
    }

    /// Live overlay only: small Claude statusline JSON. Does not spawn CLIs
    /// and does not tail Grok's unified.jsonl (HTTP billing is the Grok source).
    func refreshLocal(forceWidgetUpdate: Bool = false) {
        let provider = localProvider
        Task(priority: .utility) {
            let claude = await provider.loadClaudeUsage()
            await MainActor.run {
                self.mergeLiveOverlay([claude], forceWidgetUpdate: forceWidgetUpdate)
            }
        }
    }

    private func refreshRemote(forceWidgetUpdate: Bool = true, completion: (() -> Void)? = nil) {
        if let completion {
            refreshCompletions.append(completion)
        }
        if remoteRefreshInFlight {
            remoteRefreshQueued = true
            return
        }
        remoteRefreshInFlight = true
        let client = remoteClient
        Task(priority: .utility) {
            async let codex = client.fetchCodex()
            async let claude = client.fetchClaude()
            async let grok = client.fetchGrok()
            async let cursor = client.fetchCursor()
            var rows = await [codex, claude, grok]
            if let cursor = await cursor {
                rows.append(cursor)
            }
            await MainActor.run {
                self.merge(rows, forceWidgetUpdate: forceWidgetUpdate)
                self.remoteRefreshInFlight = false
                if self.remoteRefreshQueued {
                    self.remoteRefreshQueued = false
                    self.refreshRemote(forceWidgetUpdate: forceWidgetUpdate)
                } else {
                    let done = self.refreshCompletions
                    self.refreshCompletions = []
                    done.forEach { $0() }
                }
            }
        }
    }

    private func merge(_ rows: [UsageRow], forceWidgetUpdate: Bool = false) {
        let previous = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.provider, $0) })
        var byProvider = previous
        for provider in [UsageProvider.codex, .claude, .grok, .cursor] {
            byProvider.removeValue(forKey: provider)
        }
        for row in rows {
            if row.freshness == .unavailable,
               let existing = previous[row.provider],
               existing.freshness != .unavailable {
                byProvider[row.provider] = existing
                continue
            }
            byProvider[row.provider] = row
        }
        applySnapshot(byProvider, forceWidgetUpdate: forceWidgetUpdate)
    }

    private func mergeLiveOverlay(_ rows: [UsageRow], forceWidgetUpdate: Bool) {
        var byProvider = Dictionary(uniqueKeysWithValues: snapshot.rows.map { ($0.provider, $0) })
        for row in rows where row.freshness == .live {
            if var existing = byProvider[row.provider] {
                if let fiveHour = row.fiveHour, fiveHour.progress != nil {
                    existing.fiveHour = fiveHour
                }
                // Claude oauth/usage is the account week/Fable. Statusline
                // seven_day is a different window and was replacing 27% with 16%.
                if row.provider == .claude {
                    if existing.weekly == nil, let weekly = row.weekly {
                        existing.weekly = weekly
                    }
                    if existing.extra == nil, let extra = row.extra {
                        existing.extra = extra
                    }
                } else {
                    if let weekly = row.weekly { existing.weekly = weekly }
                    if let extra = row.extra { existing.extra = extra }
                }
                if row.provider == .grok {
                    existing.fiveHour = nil
                }
                existing.freshness = .live
                existing.updatedAt = row.updatedAt ?? existing.updatedAt
                let primary = existing.weekly ?? existing.extra ?? existing.fiveHour
                existing.detail = primary?.detail ?? existing.detail
                existing.valueText = primary?.valueText ?? existing.valueText
                existing.progress = primary?.progress ?? existing.progress
                existing.resetAt = row.resetAt ?? existing.resetAt
                byProvider[row.provider] = existing
            } else {
                byProvider[row.provider] = row
            }
        }
        applySnapshot(byProvider, forceWidgetUpdate: forceWidgetUpdate)
    }

    private func applySnapshot(_ byProvider: [UsageProvider: UsageRow], forceWidgetUpdate: Bool) {
        let ordered = byProvider.values.sorted { $0.sortOrder < $1.sortOrder }
        let nextSnapshot = UsageSnapshot(rows: ordered, updatedAt: Date(), isRefreshing: isRefreshing)
        guard forceWidgetUpdate || rowsNeedWidgetUpdate(nextSnapshot.rows, snapshot.rows) else { return }
        snapshot = nextSnapshot
        WidgetSnapshotStore.write(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetSnapshotStore.widgetKind)
    }

    private func rowsNeedWidgetUpdate(_ next: [UsageRow], _ current: [UsageRow]) -> Bool {
        guard next.count == current.count else { return true }
        return zip(next, current).contains { !isWidgetVisibleEquivalent($0, $1) }
    }

    private func isWidgetVisibleEquivalent(_ lhs: UsageRow, _ rhs: UsageRow) -> Bool {
        lhs.provider == rhs.provider
            && lhs.title == rhs.title
            && lhs.detail == rhs.detail
            && lhs.valueText == rhs.valueText
            && progressBucket(lhs.progress) == progressBucket(rhs.progress)
            && lhs.fiveHour == rhs.fiveHour
            && lhs.weekly == rhs.weekly
            && lhs.extra == rhs.extra
            && lhs.unit == rhs.unit
            && lhs.resetAt == rhs.resetAt
            && lhs.sortOrder == rhs.sortOrder
    }

    private func progressBucket(_ progress: Double?) -> Int {
        guard let progress else { return -1 }
        return Int((progress * 100).rounded())
    }

    private func startFileMonitor() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support/AIUsageWidget", isDirectory: true)
        let paths = [
            support.appendingPathComponent("claude_status_usage.json"),
            support.appendingPathComponent("claude_rate_limits.json")
        ]
        monitor = FileEventMonitor(paths: paths, debounce: 5) { [weak self] in
            Task { @MainActor in self?.refreshLocal() }
        }
        monitor?.start()

        let requestURL = WidgetSnapshotStore.refreshRequestURL
        lastRefreshRequestMTime = Self.modificationDate(of: requestURL)
        try? FileManager.default.createDirectory(
            at: requestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        refreshRequestMonitor = FileEventMonitor(paths: [requestURL.deletingLastPathComponent()], debounce: 0.05) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let mtime = Self.modificationDate(of: requestURL)
                guard let mtime, mtime != self.lastRefreshRequestMTime else { return }
                self.lastRefreshRequestMTime = mtime
                self.forceRefreshNow()
            }
        }
        refreshRequestMonitor?.start()
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func startPollTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshRemote(forceWidgetUpdate: false) }
        }
        pollTimer?.tolerance = 60
    }
}
