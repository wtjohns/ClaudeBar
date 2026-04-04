import Foundation

final class AdminApiService {
    private let base = "https://api.anthropic.com"
    private let version = "2023-06-01"

    func fetchData(adminKey: String) async throws -> AdminApiData {
        let now = Date()
        let start = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        let fmt = ISO8601DateFormatter()
        let startStr = fmt.string(from: start)

        async let usage = fetchUsage(adminKey: adminKey, startDate: startStr)
        async let cost = fetchCost(adminKey: adminKey, startDate: startStr)
        async let credit = fetchCredit(adminKey: adminKey)

        let (u, c, cr) = try await (usage, cost, credit)

        // Aggregate tokens
        var totalInput = 0, totalOutput = 0, totalCached = 0
        var byModel: [String: Int] = [:]
        for bucket in u.data {
            for r in bucket.results {
                totalInput += r.uncachedInputTokens
                totalOutput += r.outputTokens
                totalCached += r.cacheReadInputTokens
                let m = r.model ?? "unknown"
                byModel[m, default: 0] += r.uncachedInputTokens + r.outputTokens + r.cacheReadInputTokens
            }
        }
        let sortedModels = byModel.sorted { $0.value > $1.value }.map { (model: $0.key, tokens: $0.value) }

        // Aggregate cost
        let totalCost = c.data.flatMap(\.results).compactMap { Double($0.amount) }.reduce(0, +)

        // Credit balance
        let creditBalance = cr.flatMap { Double($0.availableCredit) }

        return AdminApiData(
            usage: AdminApiData.UsageSummary(
                totalInputTokens: totalInput,
                totalOutputTokens: totalOutput,
                totalCachedTokens: totalCached,
                byModel: sortedModels
            ),
            cost: AdminApiData.CostSummary(totalCost: totalCost),
            creditBalance: creditBalance,
            startDate: start,
            endDate: now
        )
    }

    // MARK: - Private

    private func fetch<T: Decodable>(_ type: T.Type, adminKey: String, path: String, query: [URLQueryItem] = []) async throws -> T {
        var comps = URLComponents(string: base + path)!
        comps.queryItems = query.isEmpty ? nil : query
        var req = URLRequest(url: comps.url!)
        req.setValue(adminKey, forHTTPHeaderField: "x-api-key")
        req.setValue(version, forHTTPHeaderField: "anthropic-version")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func fetchUsage(adminKey: String, startDate: String) async throws -> UsageReportResponse {
        try await fetch(UsageReportResponse.self, adminKey: adminKey,
                        path: "/v1/organizations/usage_report/messages",
                        query: [
                            URLQueryItem(name: "starting_at", value: startDate),
                            URLQueryItem(name: "group_by[]", value: "model"),
                            URLQueryItem(name: "limit", value: "31")
                        ])
    }

    private func fetchCost(adminKey: String, startDate: String) async throws -> CostReportResponse {
        try await fetch(CostReportResponse.self, adminKey: adminKey,
                        path: "/v1/organizations/cost_report",
                        query: [
                            URLQueryItem(name: "starting_at", value: startDate),
                            URLQueryItem(name: "limit", value: "31")
                        ])
    }

    private func fetchCredit(adminKey: String) async throws -> CreditBalanceResponse? {
        try? await fetch(CreditBalanceResponse.self, adminKey: adminKey,
                         path: "/v1/organizations/credit_balance")
    }
}
