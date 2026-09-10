import Foundation

actor LocalUsageProvider {
    private var fileManager: FileManager { FileManager.default }
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plainDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Per-file parse cache keyed by path, invalidated on (modified, size) mismatch.
    /// `loadCodexUsage` only keeps the single most-recent `token_count` event per
    /// file, so that's all this needs to retain. Actor isolation makes this safe
    /// against the concurrent `async let` callers in `UsageStore`.
    private var codexFileCache: [String: (modified: Date, size: UInt64, latest: CodexLatestEvents)] = [:]

    func loadCodexUsage() -> UsageRow {
        let sessions = home.appendingPathComponent(".codex/sessions")
        guard fileManager.fileExists(atPath: sessions.path) else {
            return UsageRow(
                provider: .codex,
                title: "Codex",
                detail: "~/.codex/sessions not found",
                valueText: "--",
                progress: nil,
                unit: .percent,
                freshness: .unavailable,
                updatedAt: nil,
                resetAt: nil,
                sortOrder: 0
            )
        }

        guard let files = recentJSONLFiles(under: sessions, days: 14, limit: 80) else {
            return .placeholder(.codex, order: 0)
        }

        // Sessions on a secondary rate-limit pool (e.g. limit_id "codex_bengalfox",
        // GPT-5.3-Codex-Spark) report that pool's used_percent, not the account's
        // main "codex" pool. Prefer the newest main-pool event; only fall back to
        // other pools when no main-pool event exists in the candidate window.
        var latestMain: CodexTokenCount?
        var latestOther: CodexTokenCount?
        var freshPaths = Set<String>()
        for file in files {
            let path = file.url.path
            freshPaths.insert(path)

            let events: CodexLatestEvents
            if let cached = codexFileCache[path],
               cached.modified == file.modified,
               cached.size == file.size {
                events = cached.latest
            } else {
                events = latestCodexTokenCounts(in: file.url)
                codexFileCache[path] = (modified: file.modified, size: file.size, latest: events)
            }

            if let event = events.main, latestMain == nil || event.timestamp > latestMain!.timestamp {
                latestMain = event
            }
            if let event = events.other, latestOther == nil || event.timestamp > latestOther!.timestamp {
                latestOther = event
            }
        }
        // Files no longer in the candidate window (rotated out by days/limit) don't
        // need to stay cached — the candidate set is already capped at `limit`.
        codexFileCache = codexFileCache.filter { freshPaths.contains($0.key) }

        guard let latest = latestMain ?? latestOther else {
            return UsageRow(
                provider: .codex,
                title: "Codex",
                detail: "No token_count events",
                valueText: "--",
                progress: nil,
                unit: .percent,
                freshness: .unavailable,
                updatedAt: nil,
                resetAt: nil,
                sortOrder: 0
            )
        }

        let detail = latest.weeklyResetAt
            .map { "Reset \(Formatters.resetString(from: $0))" }
            ?? "Weekly window"
        let weeklyMetric = percentMetric(
            label: "Week",
            usedPercent: latest.weeklyUsedPercent,
            resetAt: latest.weeklyResetAt
        )
        let fiveHourMetric = latest.primaryUsedPercent.map {
            percentMetric(label: "5h", usedPercent: $0, resetAt: latest.primaryResetAt)
        }

        return UsageRow(
            provider: .codex,
            title: "Codex",
            detail: detail,
            valueText: weeklyMetric.valueText,
            progress: weeklyMetric.progress,
            fiveHour: fiveHourMetric,
            weekly: weeklyMetric,
            unit: .percent,
            freshness: latest.timestamp.timeIntervalSinceNow > -120 ? .live : .recent,
            updatedAt: latest.timestamp,
            resetAt: latest.weeklyResetAt,
            sortOrder: 0
        )
    }

    func loadClaudeUsage() -> UsageRow {
        if let rateLimitRow = loadClaudeRateLimitUsage() {
            return rateLimitRow
        }

        return UsageRow(
            provider: .claude,
            title: "Claude",
            detail: "Waiting /usage",
            valueText: "--",
            progress: nil,
            unit: .percent,
            freshness: .unavailable,
            updatedAt: nil,
            resetAt: nil,
            sortOrder: 1
        )
    }

    /// SuperGrok weekly credit usage from Grok Build unified log
    /// (`billing: fetched credits config` → `creditUsagePercent`).
    /// Grok does not expose a 5h window locally — weekly only.
    func loadGrokUsage() -> UsageRow {
        let logURL = home.appendingPathComponent(".grok/logs/unified.jsonl")
        guard fileManager.fileExists(atPath: logURL.path) else {
            return UsageRow(
                provider: .grok,
                title: "Grok",
                detail: "~/.grok/logs not found",
                valueText: "--",
                progress: nil,
                unit: .percent,
                freshness: .unavailable,
                updatedAt: nil,
                resetAt: nil,
                sortOrder: 2
            )
        }

        guard let latest = latestGrokBillingConfig(from: logURL) else {
            return UsageRow(
                provider: .grok,
                title: "Grok",
                detail: "No billing events yet",
                valueText: "--",
                progress: nil,
                unit: .percent,
                freshness: .unavailable,
                updatedAt: nil,
                resetAt: nil,
                sortOrder: 2
            )
        }

        let usedPercent = max(0, min(latest.creditUsagePercent, 100))
        let weeklyMetric = percentMetric(
            label: "Week",
            usedPercent: usedPercent,
            resetAt: latest.periodEnd
        )
        let detail = latest.periodEnd
            .map { "Reset \(Formatters.resetString(from: $0))" }
            ?? "Weekly credits"

        return UsageRow(
            provider: .grok,
            title: "Grok",
            detail: detail,
            valueText: weeklyMetric.valueText,
            progress: weeklyMetric.progress,
            fiveHour: nil,
            weekly: weeklyMetric,
            unit: .percent,
            freshness: latest.timestamp.timeIntervalSinceNow > -10 * 60 ? .live : .recent,
            updatedAt: latest.timestamp,
            resetAt: latest.periodEnd,
            sortOrder: 2
        )
    }

    private func latestGrokBillingConfig(from url: URL) -> GrokBillingConfig? {
        // Tail scan — billing events appear throughout the log as sessions start.
        for line in tailLines(from: url, maxBytes: 2 * 1024 * 1024).reversed() {
            guard line.contains("billing: fetched credits config"),
                  line.contains("creditUsagePercent") else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let config = parseGrokBillingConfig(object) else { continue }
            return config
        }
        return nil
    }

    private func parseGrokBillingConfig(_ object: [String: Any]) -> GrokBillingConfig? {
        let timestamp = (object["ts"] as? String).flatMap(parseDate) ?? Date()
        guard let ctx = object["ctx"] as? [String: Any],
              let config = ctx["config"] as? [String: Any],
              let used = number(config["creditUsagePercent"]) else {
            return nil
        }

        var periodEnd: Date?
        if let period = config["currentPeriod"] as? [String: Any] {
            periodEnd = (period["end"] as? String).flatMap(parseDate)
        }
        if periodEnd == nil {
            periodEnd = (config["billingPeriodEnd"] as? String).flatMap(parseDate)
        }

        return GrokBillingConfig(
            timestamp: timestamp,
            creditUsagePercent: used,
            periodEnd: periodEnd
        )
    }

    private func loadClaudeRateLimitUsage() -> UsageRow? {
        let support = home.appendingPathComponent("Library/Application Support/AIUsageWidget", isDirectory: true)
        let statusUsageURL = support.appendingPathComponent("claude_status_usage.json")
        let statuslineURL = support.appendingPathComponent("claude_rate_limits.json")
        let statuslineRow = loadClaudeRateLimitUsage(from: statuslineURL)

        if let row = loadClaudeRateLimitUsage(from: statusUsageURL) {
            return mergeClaudeUsage(
                primary: row,
                fallback: statuslineRow,
                preferFresherFiveHourFromFallback: true
            )
        }

        return statuslineRow
    }

    private func loadClaudeRateLimitUsage(from url: URL) -> UsageRow? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let capturedAt = (object["captured_at"] as? String).flatMap(parseDate) ?? Date.distantPast
        let root = object["rate_limits"] ?? object
        let candidates = extractClaudeRateLimitCandidates(from: root, path: [])
            .filter(isCurrentClaudeRateLimitCandidate)
        guard let candidate = preferredClaudeRateLimit(from: candidates) else { return nil }
        let fiveHourCandidate = preferredClaudeFiveHourRateLimit(from: candidates)

        let usedPercent = max(0, min(candidate.usedPercentage, 100))
        let detail = candidate.resetsAt
            .map { "Reset \(Formatters.resetString(from: $0))" }
            ?? "Claude usage"
        let weeklyMetric = percentMetric(
            label: "Week",
            usedPercent: usedPercent,
            resetAt: candidate.resetsAt
        )
        let fiveHourMetric = fiveHourCandidate.map {
            percentMetric(label: "5h", usedPercent: $0.usedPercentage, resetAt: $0.resetsAt)
        }
        let fableMetric = preferredClaudeFableRateLimit(from: candidates).map {
            percentMetric(label: "Fable", usedPercent: $0.usedPercentage, resetAt: $0.resetsAt)
        }

        return UsageRow(
            provider: .claude,
            title: "Claude",
            detail: detail,
            valueText: weeklyMetric.valueText,
            progress: weeklyMetric.progress,
            fiveHour: fiveHourMetric,
            weekly: weeklyMetric,
            extra: fableMetric,
            unit: .percent,
            freshness: capturedAt.timeIntervalSinceNow > -5 * 60 ? .live : .recent,
            updatedAt: capturedAt,
            resetAt: candidate.resetsAt,
            sortOrder: 1
        )
    }

    private func mergeClaudeUsage(
        primary: UsageRow,
        fallback: UsageRow?,
        preferFresherFiveHourFromFallback: Bool = false
    ) -> UsageRow {
        guard let fallback else { return primary }
        var merged = primary
        if merged.fiveHour == nil {
            merged.fiveHour = fallback.fiveHour
        } else if preferFresherFiveHourFromFallback,
                  shouldUseFresherClaudeFiveHour(from: fallback, over: primary) {
            merged.fiveHour = fallback.fiveHour
            merged.updatedAt = [merged.updatedAt, fallback.updatedAt].compactMap { $0 }.max()
            if fallback.freshness == .live {
                merged.freshness = .live
            }
        }
        if merged.weekly == nil {
            merged.weekly = fallback.weekly
        }
        if merged.extra == nil {
            merged.extra = fallback.extra
        }
        return merged
    }

    private func shouldUseFresherClaudeFiveHour(from candidate: UsageRow, over baseline: UsageRow) -> Bool {
        guard let candidateFiveHour = candidate.fiveHour,
              let candidateUpdatedAt = candidate.updatedAt,
              let baselineUpdatedAt = baseline.updatedAt,
              candidateUpdatedAt > baselineUpdatedAt,
              claudeWeeklyWindowIsCompatible(candidate, baseline) else { return false }

        guard let baselineFiveHour = baseline.fiveHour else { return true }
        if candidateFiveHour.detail != baselineFiveHour.detail {
            return true
        }

        return (candidateFiveHour.progress ?? -1) >= (baselineFiveHour.progress ?? -1)
    }

    private func claudeWeeklyWindowIsCompatible(_ lhs: UsageRow, _ rhs: UsageRow) -> Bool {
        guard let lhsProgress = lhs.weekly?.progress,
              let rhsProgress = rhs.weekly?.progress else { return true }

        let progressDelta = abs(lhsProgress - rhsProgress)
        if progressDelta <= 0.05 {
            return true
        }

        return lhs.weekly?.detail == rhs.weekly?.detail && progressDelta <= 0.08
    }

    private func isCurrentClaudeRateLimitCandidate(_ candidate: ClaudeRateLimitCandidate) -> Bool {
        guard let resetsAt = candidate.resetsAt else { return true }
        return resetsAt > Date().addingTimeInterval(-60)
    }

    private func extractClaudeRateLimitCandidates(from value: Any, path: [String]) -> [ClaudeRateLimitCandidate] {
        if let dict = value as? [String: Any] {
            let used = number(dict["used_percentage"])
                ?? number(dict["used_percent"])
                ?? number(dict["usedPercentage"])
            if let used {
                let resetsAt = dateValue(dict["resets_at"])
                    ?? dateValue(dict["reset_at"])
                    ?? dateValue(dict["resetsAt"])
                let pathLabel = path.joined(separator: ".")
                let displayLabel = dict["label"] as? String
                let label = [pathLabel, displayLabel]
                    .compactMap { value in
                        guard let value, !value.isEmpty else { return nil }
                        return value
                    }
                    .joined(separator: " ")
                return [ClaudeRateLimitCandidate(label: label, usedPercentage: used, resetsAt: resetsAt)]
            }

            return dict.flatMap { key, child in
                extractClaudeRateLimitCandidates(from: child, path: path + [key])
            }
        }

        if let array = value as? [Any] {
            return array.enumerated().flatMap { index, child in
                extractClaudeRateLimitCandidates(from: child, path: path + ["\(index)"])
            }
        }

        return []
    }

    private func preferredClaudeRateLimit(from candidates: [ClaudeRateLimitCandidate]) -> ClaudeRateLimitCandidate? {
        let weeklyCandidates = candidates
            .map { (score: claudeWeeklyScore($0), candidate: $0) }
            .filter { $0.score > 0 }

        if let weekly = weeklyCandidates.max(by: { left, right in
            if left.score != right.score {
                return left.score < right.score
            }
            if left.candidate.usedPercentage != right.candidate.usedPercentage {
                return left.candidate.usedPercentage < right.candidate.usedPercentage
            }
            return (left.candidate.resetsAt ?? .distantPast) < (right.candidate.resetsAt ?? .distantPast)
        }) {
            return weekly.candidate
        }

        return candidates.max { left, right in
            (left.resetsAt ?? .distantPast) < (right.resetsAt ?? .distantPast)
        }
    }

    private func preferredClaudeFiveHourRateLimit(from candidates: [ClaudeRateLimitCandidate]) -> ClaudeRateLimitCandidate? {
        let fiveHourCandidates = candidates
            .map { (score: claudeFiveHourScore($0), candidate: $0) }
            .filter { $0.score > 0 }

        return fiveHourCandidates.max { left, right in
            if left.score != right.score {
                return left.score < right.score
            }
            return (left.candidate.resetsAt ?? .distantPast) < (right.candidate.resetsAt ?? .distantPast)
        }?.candidate
    }

    private func preferredClaudeFableRateLimit(from candidates: [ClaudeRateLimitCandidate]) -> ClaudeRateLimitCandidate? {
        let fableCandidates = candidates
            .map { (score: claudeFableScore($0), candidate: $0) }
            .filter { $0.score > 0 }
        return fableCandidates.max { left, right in
            if left.score != right.score {
                return left.score < right.score
            }
            return (left.candidate.resetsAt ?? .distantPast) < (right.candidate.resetsAt ?? .distantPast)
        }?.candidate
    }

    private func claudeFableScore(_ candidate: ClaudeRateLimitCandidate) -> Int {
        let label = candidate.label.lowercased()
        guard label.contains("fable") else { return 0 }
        var score = 80
        if label.contains("week") || label.contains("seven_day") || label.contains("7d") {
            score += 40
        }
        if label.contains("five_hour") || label.contains("5h") || label.contains("session") {
            score -= 80
        }
        return score
    }

    private func claudeWeeklyScore(_ candidate: ClaudeRateLimitCandidate) -> Int {
        let label = candidate.label.lowercased()
        var score = 0

        if label.contains("seven_day") || label.contains("7_day") || label.contains("7d") {
            score += 120
        }
        if label.contains("weekly") || label.contains("current week") {
            score += 110
        } else if label.contains("week") {
            score += 90
        }
        if label.contains("all models") {
            score += 30
        }
        if label.contains("secondary") {
            score += 40
        }
        if label.contains("five_hour")
            || label.contains("5_hour")
            || label.contains("5-hour")
            || label.contains("five hour")
            || label.contains("session") {
            score -= 160
        }
        if label.contains("fable") {
            score -= 40
        }

        return score
    }

    private func claudeFiveHourScore(_ candidate: ClaudeRateLimitCandidate) -> Int {
        let label = candidate.label.lowercased()
        var score = 0

        if label.contains("five_hour")
            || label.contains("5_hour")
            || label.contains("5-hour")
            || label.contains("five hour")
            || label.contains("5h") {
            score += 120
        }
        if label.contains("current session") || label == "session" {
            score += 100
        } else if label.contains("session") {
            score += 70
        }
        if label.contains("primary") {
            score += 30
        }
        if label.contains("seven_day")
            || label.contains("7_day")
            || label.contains("weekly")
            || label.contains("week") {
            score -= 120
        }

        return score
    }

    private func recentJSONLFiles(under root: URL, days: Int, limit: Int) -> [(url: URL, modified: Date, size: UInt64)]? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 3600)
        var candidates: [(url: URL, modified: Date, size: UInt64)] = []

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff else { continue }
            let size = UInt64(max(0, values.fileSize ?? 0))
            candidates.append((url, modified, size))
        }

        return Array(
            candidates
                .sorted { $0.modified > $1.modified }
                .prefix(limit)
        )
    }

    /// Scans a single file's tail for `token_count` events and returns the most
    /// recent one per pool (main "codex" pool vs. any other limit_id). Extracted
    /// so `loadCodexUsage` can cache the per-file result.
    private func latestCodexTokenCounts(in file: URL) -> CodexLatestEvents {
        var main: CodexTokenCount?
        var other: CodexTokenCount?
        for line in tailLines(from: file, maxBytes: 512 * 1024) {
            guard line.contains("\"token_count\""), line.contains("\"rate_limits\"") else { continue }
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = parseCodexTokenCount(object) else { continue }
            if event.isMainPool {
                if main == nil || event.timestamp > main!.timestamp {
                    main = event
                }
            } else if other == nil || event.timestamp > other!.timestamp {
                other = event
            }
        }
        return CodexLatestEvents(main: main, other: other)
    }

    private func parseCodexTokenCount(_ object: [String: Any]) -> CodexTokenCount? {
        guard let timestampString = object["timestamp"] as? String,
              let timestamp = parseDate(timestampString),
              let payload = object["payload"] as? [String: Any],
              let rateLimits = payload["rate_limits"] as? [String: Any],
              let weekly = codexRateLimitWindow(in: rateLimits, minutes: 10_080, fallbackKey: "secondary") else { return nil }

        let fiveHour = codexRateLimitWindow(in: rateLimits, minutes: 300, fallbackKey: "primary")
        let limitId = rateLimits["limit_id"] as? String

        return CodexTokenCount(
            timestamp: timestamp,
            limitId: limitId,
            weeklyUsedPercent: weekly.usedPercent,
            weeklyResetAt: weekly.resetAt,
            primaryUsedPercent: fiveHour?.usedPercent,
            primaryResetAt: fiveHour?.resetAt
        )
    }

    private func codexRateLimitWindow(in rateLimits: [String: Any], minutes targetMinutes: Double, fallbackKey: String) -> CodexRateLimitWindow? {
        var fallback: CodexRateLimitWindow?
        var matched: CodexRateLimitWindow?

        for (key, value) in rateLimits {
            guard let window = codexRateLimitWindow(from: value) else { continue }
            if key == fallbackKey {
                fallback = window
            }
            if let minutes = window.windowMinutes,
               abs(minutes - targetMinutes) < 0.5,
               matched == nil || (window.resetAt ?? .distantPast) > (matched?.resetAt ?? .distantPast) {
                matched = window
            }
        }

        // A fallback window that declares a *different* window_minutes is not this
        // metric (e.g. new-schema `primary` is the 10080-min weekly window, so it
        // must not be reported as the 5h metric). Only use the fallback when it
        // doesn't contradict the requested window size.
        if matched == nil, let fallback, let minutes = fallback.windowMinutes,
           abs(minutes - targetMinutes) >= 0.5 {
            return nil
        }
        return matched ?? fallback
    }

    private func codexRateLimitWindow(from value: Any) -> CodexRateLimitWindow? {
        guard let dict = value as? [String: Any],
              let usedPercent = number(dict["used_percent"])
                ?? number(dict["usedPercentage"]) else { return nil }
        let resetAt = number(dict["resets_at"])
            .or(number(dict["resetsAt"]))
            .map { Date(timeIntervalSince1970: $0) }
        return CodexRateLimitWindow(
            usedPercent: usedPercent,
            resetAt: resetAt,
            windowMinutes: number(dict["window_minutes"]) ?? number(dict["windowMinutes"])
        )
    }

    private func parseDate(_ value: String) -> Date? {
        if let date = fractionalDateFormatter.date(from: value) {
            return date
        }

        return plainDateFormatter.date(from: value)
    }

    private func dateValue(_ value: Any?) -> Date? {
        if let number = number(value) {
            return Date(timeIntervalSince1970: number)
        }
        if let string = value as? String {
            return parseDate(string)
        }
        return nil
    }

    private func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func percentMetric(label: String, usedPercent: Double, resetAt: Date?) -> UsageWindowMetric {
        let clampedPercent = max(0, min(usedPercent, 100))
        let detail = resetAt
            .map { "Reset \(Formatters.resetString(from: $0))" }
            ?? label
        return UsageWindowMetric(
            label: label,
            valueText: "\(Int(clampedPercent.rounded()))%",
            progress: clampedPercent / 100,
            detail: detail,
            resetAt: resetAt
        )
    }

    private func tailLines(from url: URL, maxBytes: UInt64) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              var text = String(data: data, encoding: .utf8) else { return [] }

        if offset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }

        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

}

private struct CodexTokenCount {
    let timestamp: Date
    let limitId: String?
    let weeklyUsedPercent: Double
    let weeklyResetAt: Date?
    let primaryUsedPercent: Double?
    let primaryResetAt: Date?

    /// Older logs have no `limit_id`; treat them as the main pool.
    var isMainPool: Bool { limitId == nil || limitId == "codex" }
}

private struct CodexLatestEvents {
    let main: CodexTokenCount?
    let other: CodexTokenCount?
}

private struct CodexRateLimitWindow {
    let usedPercent: Double
    let resetAt: Date?
    let windowMinutes: Double?
}

private struct ClaudeRateLimitCandidate {
    let label: String
    let usedPercentage: Double
    let resetsAt: Date?
}

private struct GrokBillingConfig {
    let timestamp: Date
    let creditUsagePercent: Double
    let periodEnd: Date?
}

private extension Optional {
    func or(_ fallback: Wrapped?) -> Wrapped? {
        self ?? fallback
    }
}
