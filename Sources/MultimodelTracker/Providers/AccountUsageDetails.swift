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
        if CommandLine.arguments.contains("--mock") {
            let rows = (0..<(account.provider == .google ? 23 : 1)).map {
                ModelUsageDetail(model: account.provider == .google ? "Gemini fixture \($0 + 1)" : "Model fixture", value: 25)
            }
            var report = UsageDetails(title: "Model quota used", rows: rows, unit: "quotaPercent",
                                      note: "Fabricated UI fixture. No provider request.")
            if account.provider == .google {
                report.googleGroups = ["Gemini Models", "Claude and GPT models"].map {
                    GoogleQuotaGroup(id: $0, title: $0, description: "Models share these weekly and five-hour limits.", rows: [
                        ModelUsageDetail(model: "Weekly", value: 25), ModelUsageDetail(model: "Five Hour", value: 15)])
                }
            }
            return Result(primary: report)
        }
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
            // Anthropic's subscription limits ARE the card; there is no
            // account-scoped model breakdown to fetch. The local Claude Code
            // collector that once filled this panel was removed before merge:
            // it reported tokens spent, never the reset offers it was built
            // to find, and never received a live event.
            throw AdapterError.transport("No model details for Anthropic")
        }
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
