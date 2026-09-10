import Foundation

struct APICostClient {
    func loadOpenAIWeeklyCost() async -> UsageRow {
        let key = KeychainStore.shared.read(.openAIAdminKey)
            ?? ProcessInfo.processInfo.environment["OPENAI_ADMIN_KEY"]
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]

        guard let key, !key.isEmpty else {
            return UsageRow(
                provider: .openAIAPI,
                title: "OpenAI API",
                detail: "Key needed",
                valueText: "--",
                progress: nil,
                unit: .usd,
                freshness: .unavailable,
                updatedAt: nil,
                resetAt: nil,
                sortOrder: 2
            )
        }

        do {
            let cost = try await fetchOpenAIWeeklyCost(apiKey: key)
            return UsageRow(
                provider: .openAIAPI,
                title: "OpenAI API",
                detail: "Official weekly cost",
                valueText: Formatters.usd(cost),
                progress: nil,
                unit: .usd,
                freshness: .official,
                updatedAt: Date(),
                resetAt: nil,
                sortOrder: 2
            )
        } catch {
            return UsageRow(
                provider: .openAIAPI,
                title: "OpenAI API",
                detail: shortError(error),
                valueText: "--",
                progress: nil,
                unit: .usd,
                freshness: .delayed,
                updatedAt: Date(),
                resetAt: nil,
                sortOrder: 2
            )
        }
    }

    func loadAnthropicWeeklyCost() async -> UsageRow {
        let key = KeychainStore.shared.read(.anthropicAdminKey)
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_ADMIN_KEY"]

        guard let key, !key.isEmpty else {
            return UsageRow(
                provider: .anthropicAPI,
                title: "Anthropic API",
                detail: "Key needed",
                valueText: "--",
                progress: nil,
                unit: .usd,
                freshness: .unavailable,
                updatedAt: nil,
                resetAt: nil,
                sortOrder: 3
            )
        }

        do {
            if let credit = AnthropicCreditStore.load() {
                let cost = try await fetchAnthropicCost(apiKey: key, interval: credit.interval)
                let remaining = max(0, credit.amount - cost)
                let progress = min(1, max(0, cost / credit.amount))
                return UsageRow(
                    provider: .anthropicAPI,
                    title: "Anthropic API",
                    detail: "Used \(Formatters.usd(cost)) / \(Formatters.usd(credit.amount))",
                    valueText: Formatters.usd(remaining),
                    progress: progress,
                    unit: .usd,
                    freshness: .official,
                    updatedAt: Date(),
                    resetAt: nil,
                    sortOrder: 3
                )
            }

            let cost = try await fetchAnthropicCost(apiKey: key, interval: currentWeekInterval())
            return UsageRow(
                provider: .anthropicAPI,
                title: "Anthropic API",
                detail: "Official weekly cost",
                valueText: Formatters.usd(cost),
                progress: nil,
                unit: .usd,
                freshness: .official,
                updatedAt: Date(),
                resetAt: nil,
                sortOrder: 3
            )
        } catch {
            return UsageRow(
                provider: .anthropicAPI,
                title: "Anthropic API",
                detail: shortError(error),
                valueText: "--",
                progress: nil,
                unit: .usd,
                freshness: .delayed,
                updatedAt: Date(),
                resetAt: nil,
                sortOrder: 3
            )
        }
    }

    private func fetchOpenAIWeeklyCost(apiKey: String) async throws -> Double {
        let interval = currentWeekInterval()
        var components = URLComponents(string: "https://api.openai.com/v1/organization/costs")!
        components.queryItems = [
            URLQueryItem(name: "start_time", value: "\(Int(interval.start.timeIntervalSince1970))"),
            URLQueryItem(name: "end_time", value: "\(Int(interval.end.timeIntervalSince1970))"),
            URLQueryItem(name: "bucket_width", value: "1d")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let json = try await fetchJSON(request)
        return CostExtractor.sumUSD(in: json)
    }

    private func fetchAnthropicCost(apiKey: String, interval: DateInterval) async throws -> Double {
        var components = URLComponents(string: "https://api.anthropic.com/v1/organizations/cost_report")!
        components.queryItems = [
            URLQueryItem(name: "starting_at", value: iso8601UTC(interval.start)),
            URLQueryItem(name: "ending_at", value: iso8601UTC(interval.end))
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("AIUsageWidget/0.1", forHTTPHeaderField: "User-Agent")

        let json = try await fetchJSON(request)
        return CostExtractor.sumUSD(in: json)
    }

    private func fetchJSON(_ request: URLRequest) async throws -> Any {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.httpStatus(http.statusCode)
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func currentWeekInterval() -> DateInterval {
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? Date().addingTimeInterval(-7 * 24 * 3600)
        return DateInterval(start: start, end: Date())
    }

    private func iso8601UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func shortError(_ error: Error) -> String {
        if let api = error as? APIError {
            return api.description
        }
        let message = error.localizedDescription
        return message.count > 38 ? String(message.prefix(38)) + "..." : message
    }
}

enum APIError: Error, CustomStringConvertible {
    case httpStatus(Int)

    var description: String {
        switch self {
        case .httpStatus(let code):
            return "HTTP \(code)"
        }
    }
}

enum CostExtractor {
    static func sumUSD(in json: Any) -> Double {
        var total = 0.0
        walk(json) { key, value in
            if key == "amount", let dict = value as? [String: Any] {
                let currency = (dict["currency"] as? String)?.lowercased()
                if currency == nil || currency == "usd" {
                    total += number(dict["value"]) ?? number(dict["amount"]) ?? 0
                }
                return
            }
            if ["cost", "cost_usd", "usd"].contains(key) {
                total += number(value) ?? 0
            }
        }
        return total
    }

    private static func walk(_ value: Any, visit: (String, Any) -> Void) {
        if let dict = value as? [String: Any] {
            for (key, child) in dict {
                visit(key, child)
                walk(child, visit: visit)
            }
        } else if let array = value as? [Any] {
            for child in array {
                walk(child, visit: visit)
            }
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

struct AnthropicCreditSettings: Equatable, Sendable {
    let amount: Double
    let startDate: Date

    var interval: DateInterval {
        DateInterval(start: startDate, end: Date())
    }
}

enum AnthropicCreditStore {
    private static let amountKey = "anthropic_credit_budget_usd"
    private static let startDateKey = "anthropic_credit_start_date"

    static func load() -> AnthropicCreditSettings? {
        let defaults = UserDefaults.standard
        let amount = storedAmount(defaults: defaults)
            ?? Double(ProcessInfo.processInfo.environment["ANTHROPIC_CREDIT_USD"] ?? "")
        let startText = defaults.string(forKey: startDateKey)
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_CREDIT_START"]

        guard let amount, amount > 0,
              let startText,
              let start = parseDate(startText) else { return nil }
        return AnthropicCreditSettings(amount: amount, startDate: start)
    }

    static func amountText() -> String {
        guard let amount = storedAmount(defaults: .standard) else { return "" }
        return amount.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", amount)
            : String(format: "%.2f", amount)
    }

    static func startDateText() -> String {
        UserDefaults.standard.string(forKey: startDateKey) ?? ""
    }

    static func save(amountText: String, startDateText: String) throws {
        let amountText = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
        let startDateText = startDateText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !amountText.isEmpty || !startDateText.isEmpty else {
            clear()
            return
        }

        guard let amount = Double(amountText), amount > 0 else {
            throw AnthropicCreditStoreError.invalidAmount
        }
        guard parseDate(startDateText) != nil else {
            throw AnthropicCreditStoreError.invalidStartDate
        }

        UserDefaults.standard.set(amount, forKey: amountKey)
        UserDefaults.standard.set(startDateText, forKey: startDateKey)
    }

    private static func clear() {
        UserDefaults.standard.removeObject(forKey: amountKey)
        UserDefaults.standard.removeObject(forKey: startDateKey)
    }

    private static func storedAmount(defaults: UserDefaults) -> Double? {
        guard defaults.object(forKey: amountKey) != nil else { return nil }
        return defaults.double(forKey: amountKey)
    }

    private static func parseDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        let isoWithFractionalSeconds = ISO8601DateFormatter()
        isoWithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithFractionalSeconds.date(from: trimmed) {
            return date
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) {
            return date
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: trimmed) else {
            return nil
        }
        return Calendar.current.startOfDay(for: date)
    }
}

enum AnthropicCreditStoreError: LocalizedError {
    case invalidAmount
    case invalidStartDate

    var errorDescription: String? {
        switch self {
        case .invalidAmount:
            return "Anthropic credit must be a positive USD amount"
        case .invalidStartDate:
            return "Anthropic credit start must be YYYY-MM-DD or ISO time"
        }
    }
}
