import Foundation
import SQLite3

/// Snapshot fetchers modeled on Orca's rate-limit service:
/// HTTP/RPC only, no `claude`/`codex exec` process to generate logs.
actor RemoteUsageClient {
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    private enum CachedSecret {
        case missing
        case value(String)
    }

    private var cachedClaudeToken: CachedSecret?
    private var cachedCursorToken: CachedSecret?

    func fetchClaude() async -> UsageRow {
        for attempt in 0 ..< 2 {
            guard let token = readClaudeAccessToken(forceReload: attempt > 0) else {
                return .placeholder(.claude, order: 1, detail: "Sign in with Claude Code")
            }
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 {
                    cachedClaudeToken = nil
                    continue
                }
                guard status == 200,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return .placeholder(.claude, order: 1, detail: "Claude usage HTTP \(status)")
                }
                let five = window(from: json["five_hour"], minutes: 300)
                let week = window(from: json["seven_day"], minutes: 10_080)
                let fable = fableWindow(from: json)
                return makeRow(
                    provider: .claude,
                    title: "Claude",
                    order: 1,
                    fiveHour: five,
                    weekly: week,
                    extra: fable,
                    extraLabel: "Fable"
                )
            } catch {
                return .placeholder(.claude, order: 1, detail: "Claude usage request failed")
            }
        }
        return .placeholder(.claude, order: 1, detail: "Claude usage HTTP 401")
    }

    func fetchCodex() async -> UsageRow {
        guard let headers = readCodexAuthHeaders() else {
            return .placeholder(.codex, order: 0, detail: "Sign in with Codex")
        }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return .placeholder(.codex, order: 0, detail: "Codex usage HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            let rate = json["rate_limit"] as? [String: Any]
            let windows = [
                backendWindow(rate?["primary_window"], fallbackMinutes: 300),
                backendWindow(rate?["secondary_window"], fallbackMinutes: 10_080)
            ].compactMap { $0 }
            let five = windows.first { $0.minutes < 1_440 }.map { ($0.percent, $0.reset) }
            let week = windows.first { $0.minutes >= 1_440 }.map { ($0.percent, $0.reset) }
                ?? windows.last.map { ($0.percent, $0.reset) }
            return makeRow(
                provider: .codex,
                title: "Codex",
                order: 0,
                fiveHour: five,
                weekly: week
            )
        } catch {
            return .placeholder(.codex, order: 0, detail: "Codex usage request failed")
        }
    }

    func fetchGrok() async -> UsageRow {
        guard let auth = readGrokAuth() else {
            return .placeholder(.grok, order: 2, detail: "Sign in with Grok CLI")
        }
        if let row = await grokBilling(
            url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!,
            auth: auth
        ) {
            return row
        }
        if let row = await grokBilling(
            url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!,
            auth: auth
        ) {
            return row
        }
        return .placeholder(.grok, order: 2, detail: "Grok billing request failed")
    }

    private func grokBilling(url: URL, auth: GrokAuth) async -> UsageRow? {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let userId = auth.userId {
            request.setValue(userId, forHTTPHeaderField: "x-userid")
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            let config = (json["config"] as? [String: Any]) ?? json
            let period = config["currentPeriod"] as? [String: Any]
            let end = parseDate(period?["end"] as? String) ?? parseDate(config["billingPeriodEnd"] as? String)
            if let weeklyPercent = grokWeeklyPercent(config) {
                let weekly = Formatters.percentMetric(label: "Week", usedPercent: weeklyPercent, resetAt: end)
                return UsageRow(
                    provider: .grok,
                    title: "Grok",
                    detail: weekly.detail,
                    valueText: weekly.valueText,
                    progress: weekly.progress,
                    fiveHour: nil,
                    weekly: weekly,
                    unit: .percent,
                    freshness: .official,
                    updatedAt: Date(),
                    resetAt: end,
                    sortOrder: 2
                )
            }
            let limit = number((config["monthlyLimit"] as? [String: Any])?["val"])
            let usedVal = number((config["used"] as? [String: Any])?["val"])
            if let limit, let usedVal, limit > 0 {
                let monthly = Formatters.percentMetric(
                    label: "Month",
                    usedPercent: min(100, max(0, usedVal / limit * 100)),
                    resetAt: end
                )
                return UsageRow(
                    provider: .grok,
                    title: "Grok",
                    detail: monthly.detail,
                    valueText: monthly.valueText,
                    progress: monthly.progress,
                    fiveHour: nil,
                    weekly: monthly,
                    unit: .percent,
                    freshness: .official,
                    updatedAt: Date(),
                    resetAt: end,
                    sortOrder: 2
                )
            }
            return nil
        } catch {
            return nil
        }
    }

    private func grokWeeklyPercent(_ config: [String: Any]) -> Double? {
        if let percent = number(config["creditUsagePercent"]) {
            return min(100, max(0, percent))
        }
        let period = config["currentPeriod"] as? [String: Any]
        guard (period?["type"] as? String) == "USAGE_PERIOD_TYPE_WEEKLY" else { return nil }
        let start = period?["start"] as? String
        let end = period?["end"] as? String
        let billingStart = config["billingPeriodStart"] as? String
        let billingEnd = config["billingPeriodEnd"] as? String
        guard start == billingStart, end == billingEnd else { return nil }
        return 0
    }

    /// Unofficial Cursor dashboard API. Omitted when no token is available.
    func fetchCursor() async -> UsageRow? {
        for attempt in 0 ..< 2 {
            guard let token = readCursorAccessToken(forceReload: attempt > 0) else { return nil }
            var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.httpBody = Data("{}".utf8)
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 {
                    cachedCursorToken = nil
                    continue
                }
                guard (200 ..< 300).contains(status),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return .placeholder(.cursor, order: 3, detail: "Cursor usage HTTP \(status)")
                }
                let plan = json["planUsage"] as? [String: Any] ?? json
                // Dashboard pools: auto = Cursor Models (Composer/Grok), api = Other Models.
                // totalPercentUsed is a blended headline, not a third pool.
                let cursorPool = number(plan["autoPercentUsed"])
                let otherPool = number(plan["apiPercentUsed"])
                guard cursorPool != nil || otherPool != nil else {
                    return .placeholder(.cursor, order: 3, detail: "Cursor payload missing percent")
                }
                let end = parseDate(json["billingCycleEnd"] as? String)
                    ?? unixDate(json["billingCycleEnd"])
                let cursorMetric = cursorPool.map {
                    Formatters.percentMetric(label: "Cursor", usedPercent: $0, resetAt: end)
                }
                let otherMetric = otherPool.map {
                    Formatters.percentMetric(label: "Other", usedPercent: $0, resetAt: end)
                }
                let primary = otherMetric ?? cursorMetric
                return UsageRow(
                    provider: .cursor,
                    title: "Cursor",
                    detail: primary?.detail ?? "Cursor usage",
                    valueText: primary?.valueText ?? "--",
                    progress: primary?.progress,
                    fiveHour: cursorMetric,
                    weekly: otherMetric,
                    unit: .percent,
                    freshness: .official,
                    updatedAt: Date(),
                    resetAt: end,
                    sortOrder: 3
                )
            } catch {
                return .placeholder(.cursor, order: 3, detail: "Cursor usage request failed")
            }
        }
        return .placeholder(.cursor, order: 3, detail: "Cursor usage HTTP 401")
    }

    // MARK: - Mapping

    private func makeRow(
        provider: UsageProvider,
        title: String,
        order: Int,
        fiveHour: (percent: Double, reset: Date?)?,
        weekly: (percent: Double, reset: Date?)?,
        extra: (percent: Double, reset: Date?)? = nil,
        extraLabel: String = "Extra"
    ) -> UsageRow {
        let weekMetric = weekly.map { Formatters.percentMetric(label: "Week", usedPercent: $0.percent, resetAt: $0.reset) }
        let fiveMetric = fiveHour.map { Formatters.percentMetric(label: "5h", usedPercent: $0.percent, resetAt: $0.reset) }
        let extraMetric = extra.map { Formatters.percentMetric(label: extraLabel, usedPercent: $0.percent, resetAt: $0.reset) }
        let primary = weekMetric ?? extraMetric ?? fiveMetric
        return UsageRow(
            provider: provider,
            title: title,
            detail: primary?.detail ?? "No windows",
            valueText: primary?.valueText ?? "--",
            progress: primary?.progress,
            fiveHour: fiveMetric,
            weekly: weekMetric,
            extra: extraMetric,
            unit: .percent,
            freshness: .official,
            updatedAt: Date(),
            resetAt: extra?.reset ?? weekly?.reset ?? fiveHour?.reset,
            sortOrder: order
        )
    }

    private func window(from raw: Any?, minutes _: Int) -> (percent: Double, reset: Date?)? {
        guard let object = raw as? [String: Any] else { return nil }
        let percent = number(object["utilization"]) ?? number(object["used_percentage"])
        guard let percent else { return nil }
        return (min(100, max(0, percent)), parseReset(object["resets_at"]))
    }

    private func fableWindow(from json: [String: Any]) -> (percent: Double, reset: Date?)? {
        if let limits = json["limits"] as? [[String: Any]] {
            let match = limits.first { limit in
                guard (limit["kind"] as? String) == "weekly_scoped" else { return false }
                let name = ((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                return name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "fable"
            }
            if let match, let percent = number(match["percent"]) {
                return (min(100, max(0, percent)), parseReset(match["resets_at"]))
            }
        }
        return window(from: json["fable_weekly"] ?? json["fable_seven_day"] ?? json["seven_day_fable"], minutes: 10_080)
    }

    private func backendWindow(
        _ raw: Any?,
        fallbackMinutes: Int
    ) -> (percent: Double, reset: Date?, minutes: Int)? {
        guard let object = raw as? [String: Any] else { return nil }
        let percent = number(object["used_percent"]) ?? number(object["usedPercent"]) ?? 0
        let seconds = number(object["limit_window_seconds"]) ?? number(object["limitWindowSeconds"])
        let minutes = seconds.flatMap { $0 > 0 ? Int(($0 / 60.0).rounded(.up)) : nil } ?? fallbackMinutes
        return (min(100, max(0, percent)), parseReset(object["reset_at"] ?? object["resetAt"]), minutes)
    }

    private func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func parseReset(_ value: Any?) -> Date? {
        if let number = number(value) {
            let ms = number > 10_000_000_000 ? number : number * 1000
            return Date(timeIntervalSince1970: ms / 1000)
        }
        if let string = value as? String {
            return parseDate(string)
        }
        return nil
    }

    private func unixDate(_ value: Any?) -> Date? {
        guard let number = number(value) else { return nil }
        let ms = number > 10_000_000_000 ? number : number * 1000
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    // MARK: - Credentials (never logged)

    private func readClaudeAccessToken(forceReload: Bool) -> String? {
        if !forceReload, let cached = cachedClaudeToken {
            if case let .value(token) = cached { return token }
            return nil
        }
        if let token = readClaudeTokenFromFiles() {
            cachedClaudeToken = .value(token)
            return token
        }
        // Claude Code stores the OAuth token in the login keychain with an
        // ACL bound to its own binary. Querying it from this ad-hoc signed
        // host always risks a password dialog, even with
        // kSecUseAuthenticationUIFail. Files only; overlay keeps last HTTP.
        cachedClaudeToken = .missing
        return nil
    }

    private func readClaudeTokenFromFiles() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for name in [".credentials.json", "credentials.json"] {
            let url = home.appendingPathComponent(".claude").appendingPathComponent(name)
            if let data = try? Data(contentsOf: url),
               let raw = String(data: data, encoding: .utf8),
               let token = claudeToken(from: raw) {
                return token
            }
        }
        return nil
    }

    private func claudeToken(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { return nil }
        return token
    }

    private func readCodexAuthHeaders() -> [String: String]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              !access.isEmpty
        else { return nil }
        var headers = [
            "Authorization": "Bearer \(access)",
            "User-Agent": "codex-cli",
            "OpenAI-Beta": "codex-1",
            "originator": "Codex Desktop"
        ]
        if let account = tokens["account_id"] as? String, !account.isEmpty {
            headers["ChatGPT-Account-Id"] = account
        }
        return headers
    }

    private struct GrokAuth {
        var token: String
        var userId: String?
    }

    private func readGrokAuth() -> GrokAuth? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let preferredPrefix = "https://auth.x.ai"
        var preferred: GrokAuth?
        var fallback: GrokAuth?
        for (issuer, value) in json {
            guard let entry = value as? [String: Any],
                  let key = entry["key"] as? String,
                  !key.isEmpty
            else { continue }
            let auth = GrokAuth(token: key, userId: entry["user_id"] as? String)
            if issuer == preferredPrefix || issuer.hasPrefix("\(preferredPrefix)::") {
                preferred = auth
            } else if fallback == nil {
                fallback = auth
            }
        }
        return preferred ?? fallback
    }

    private func readCursorAccessToken(forceReload: Bool) -> String? {
        if !forceReload, let cached = cachedCursorToken {
            if case let .value(token) = cached { return token }
            return nil
        }
        if let env = ProcessInfo.processInfo.environment["CURSOR_API_KEY"], !env.isEmpty {
            cachedCursorToken = .value(env)
            return env
        }
        if let token = cursorTokenFromStateDB() {
            cachedCursorToken = .value(token)
            return token
        }
        cachedCursorToken = .missing
        return nil
    }

    /// Cursor Desktop stores the session token in `cursorAuth/accessToken`.
    /// Read-only; the token is never logged.
    private func cursorTokenFromStateDB() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let cString = sqlite3_column_text(statement, 0)
        else { return nil }
        let trimmed = String(cString: cString).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? String,
           !decoded.isEmpty {
            return decoded
        }
        return trimmed
    }

}

extension UsageRow {
    static func placeholder(_ provider: UsageProvider, order: Int, detail: String) -> UsageRow {
        UsageRow(
            provider: provider,
            title: provider.rawValue,
            detail: detail,
            valueText: "--",
            progress: nil,
            unit: .unknown,
            freshness: .unavailable,
            updatedAt: nil,
            resetAt: nil,
            sortOrder: order
        )
    }
}
