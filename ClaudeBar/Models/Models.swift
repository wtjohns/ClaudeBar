import Foundation

// MARK: - Usage

struct UsageBar: Identifiable, Sendable {
    let id = UUID()
    let label: String
    let percentage: Double
    let resetInfo: String
}

struct ClaudeUsage {
    let bars: [UsageBar]
    let isAuthenticated: Bool
    let plan: String?
}

struct CodexUsage: Sendable {
    let bars: [UsageBar]
    let plan: String?
    let limitReached: Bool
    /// nil when fetched live; otherwise when the session-log snapshot was written
    let snapshotDate: Date?
}

/// "Resets at 11:50 AM" for today, otherwise "Resets Wed 1:00 AM"
func resetDescription(for date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
        return "Resets at \(date.formatted(date: .omitted, time: .shortened))"
    }
    return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
}

// MARK: - Billing

struct BillingInfo {
    let creditBalance: Double?
    let currency: String
}

// MARK: - Admin API

struct AdminApiData {
    struct UsageSummary {
        let totalInputTokens: Int
        let totalOutputTokens: Int
        let totalCachedTokens: Int
        let byModel: [(model: String, tokens: Int)]  // sorted descending
    }
    struct CostSummary {
        let totalCost: Double
    }
    let usage: UsageSummary
    let cost: CostSummary
    let creditBalance: Double?
    let startDate: Date
    let endDate: Date
}

// MARK: - Logging

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String
}

// MARK: - Admin API Codable responses

struct UsageReportResponse: Decodable {
    let data: [UsageTimeBucket]
}

struct UsageTimeBucket: Decodable {
    let results: [UsageResult]
}

struct UsageResult: Decodable {
    let uncachedInputTokens: Int
    let cacheReadInputTokens: Int
    let outputTokens: Int
    let model: String?

    enum CodingKeys: String, CodingKey {
        case uncachedInputTokens = "uncached_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case outputTokens = "output_tokens"
        case model
    }
}

struct CostReportResponse: Decodable {
    let data: [CostTimeBucket]
}

struct CostTimeBucket: Decodable {
    let results: [CostResult]
}

struct CostResult: Decodable {
    let amount: String
}

struct CreditBalanceResponse: Decodable {
    let availableCredit: String
    enum CodingKeys: String, CodingKey {
        case availableCredit = "available_credit"
    }
}
