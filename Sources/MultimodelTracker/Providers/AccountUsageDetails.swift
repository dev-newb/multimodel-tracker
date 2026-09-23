import Foundation

/// The native detail panel and diagnostic path use the same account-scoped reads.
@MainActor
enum AccountUsageDetails {
    struct Result {
        var primary: UsageDetails
        var tokens: UsageDetails? = nil
        var warning: String? = nil
    }

    static func fetch(_ account: Account) async throws -> Result {
        switch account.provider {
        case .openai:
            let creds = try await Keychain.openAICredentialsAsync(for: account.id)
            do { return Result(primary: try await OpenAIModelUsage.fetch(creds)) }
            catch AdapterError.notSignedIn {
                _ = try await OpenAIAdapter().fetch(account: account)
                return Result(primary: try await OpenAIModelUsage.fetch(Keychain.openAICredentialsAsync(for: account.id)))
            }
        case .google:
            return Result(primary: try await GoogleAdapterImpl().fetchModelDetails(account: account))
        case .anthropic:
            // The main account refresh already obtained these exact limits. Reuse them
            // so opening/refreshing details cannot double OAuth polling or trigger 429s.
            let scoped = account.limits.filter { $0.key.hasPrefix("weekly_scoped") || $0.key.hasPrefix("seven_day_") }
            var result = Result(primary: UsageDetails(title: "Model-specific quota used", rows: scoped.compactMap { limit in
                guard let percent = limit.percent, percent.isFinite else { return nil }
                return .init(model: limit.label, value: min(max(percent, 0), 100), identifier: limit.key, caption: limit.resetDetail)
            }, unit: "quotaPercent", note: "Current limits reported by Anthropic for this account. Per-model token totals require local Claude Code collection.", emptyMessage: "Anthropic reports no separate model limits for this account."))
            if let error = account.error { result.warning = "Account refresh: \(error). Showing the last reported limits." }
            if await ClaudeUsageLedger.shared.hasEvents() {
                do { result.tokens = try await claudeTokens(account) }
                catch { result.warning = "Claude Code totals: \(String(describing: error))" }
            } else if ClaudeTelemetry.shared.enabled {
                result.tokens = UsageDetails(title: "Claude Code · last 7 days", note: "Only new Claude Code activity on this Mac can be collected. Desktop chat and past conversations are not included.", emptyMessage: "No Claude Code usage events received yet.")
            }
            return result
        }
    }

    private static func claudeTokens(_ account: Account) async throws -> UsageDetails {
        let creds = try await Keychain.anthropicCredentialsAsync(for: account.id)
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        req.timeoutInterval = 15
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue(AnthropicOAuth.betaHeader, forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let owner = root["account"] as? [String: Any], let uuid = owner["uuid"] as? String,
              let org = root["organization"] as? [String: Any], let orgID = org["uuid"] as? String else {
            throw AdapterError.transport("Cannot verify account identity for local Claude Code totals")
        }
        return await ClaudeUsageLedger.shared.report(account: uuid, organization: orgID)
    }

    /// Explicit developer opt-in. Records only provider names, models, amounts and errors;
    /// no tokens, emails, account IDs, cookies or raw responses. Keeps the normal app running.
    static func diagnose(_ accounts: [Account], to url: URL) async {
        var results: [[String: Any]] = []
        for account in accounts {
            var row: [String: Any] = ["provider": account.provider.rawValue]
            do {
                let result = try await fetch(account)
                row["title"] = result.primary.title
                row["unit"] = result.primary.unit
                row["rows"] = result.primary.rows.map { ["model": $0.model, "value": $0.value] as [String: Any] }
                row["note"] = result.primary.note
                row["tokenRows"] = result.tokens?.rows.count ?? 0
                row["warning"] = result.warning
            } catch { row["error"] = String(describing: error) }
            results.append(row)
            if let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }
        }
    }
}
