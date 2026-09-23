import SwiftUI

@MainActor
struct UsageDetailsView: View {
    let account: Account
    let accent: Color
    var preview: UsageDetails? = nil
    @State private var details: UsageDetails?
    @State private var resetNote: String?
    @State private var failure: String?
    @State private var loading = true
    @ObservedObject private var telemetry = ClaudeTelemetry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            if loading && preview == nil { ProgressView().controlSize(.small) }
            if let details = preview ?? details {
                Text(details.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(details.rows) { row in
                    VStack(spacing: 3) {
                        HStack {
                            Text(row.model).lineLimit(1).help(row.model)
                            Spacer(minLength: 4)
                            Text(value(row.value, unit: details.unit)).monospacedDigit()
                        }.font(.system(size: 10))
                        GeometryReader { g in
                            Capsule().fill(accent.opacity(0.12))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(accent).frame(width: g.size.width * row.value / max(details.rows.map(\.value).max() ?? 1, 1))
                                }
                        }.frame(height: 4)
                    }
                }
                if details.rows.isEmpty { Text("No attributed model usage received.").font(.system(size: 10)).foregroundStyle(.secondary) }
                Text(details.note).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let failure { Text(failure).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let resetNote {
                Text("Resets").font(.system(size: 10, weight: .semibold))
                Text(resetNote).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Connect Claude web for reset offers") { WebSessionPool.shared.connectResetSession(for: account) }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(accent)
                Link("Open Claude Usage", destination: URL(string: "https://claude.ai/settings/usage")!).font(.system(size: 10))
            }
            if account.provider == .anthropic {
                Text(telemetry.status).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !telemetry.enabled {
                    Button("Enable local Claude Code collection") { telemetry.enable() }.controlSize(.small)
                } else {
                    Button("Stop local collection") { telemetry.disable() }.font(.system(size: 10)).buttonStyle(.plain)
                }
            }
            if !loading && account.provider != .google {
                Button("Refresh details") { Task { await refresh() } }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(accent)
            }
        }
        .task(id: account.id) {
            guard preview == nil else { return }
            repeat {
                await refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            } while !Task.isCancelled
        }
    }
    private func value(_ n: Double, unit: String) -> String {
        if unit == "percent" { return String(format: "%.2f pp", n) }
        if unit == "credits" { return String(format: "%.2f credits", n) }
        return n.formatted(.number.notation(.compactName)) + " tokens"
    }
    private func refresh() async {
        guard !Task.isCancelled else { return }
        loading = true; failure = nil; details = nil; resetNote = nil
        defer { loading = false }
        do {
            switch account.provider {
            case .openai:
                let creds = try await Keychain.openAICredentialsAsync(for: account.id)
                details = try await OpenAIModelUsage.fetch(creds)
            case .anthropic:
                let creds = try await Keychain.anthropicCredentialsAsync(for: account.id)
                async let resets = ClaudeResetDiscovery.fetch(token: creds.accessToken)
                var webResetNote: String?
                var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
                req.timeoutInterval = 15
                req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
                req.setValue(AnthropicOAuth.betaHeader, forHTTPHeaderField: "anthropic-beta")
                if let (data, response) = try? await URLSession.shared.data(for: req),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let owner = root["account"] as? [String: Any], let uuid = owner["uuid"] as? String,
                   let org = root["organization"] as? [String: Any], let orgID = org["uuid"] as? String {
                    details = await ClaudeUsageLedger.shared.report(account: uuid, organization: orgID)
                    if UserDefaults.standard.bool(forKey: "mmt.claudeWebResets.\(account.id)") {
                        do { webResetNote = try await WebSessionPool.shared.fetchResetOffers(for: account, expectedAccount: uuid, organization: orgID) }
                        catch { webResetNote = String(describing: error) }
                    }
                } else {
                    failure = "Cannot verify this account’s identity. Local usage is not assigned by email or current login."
                }
                let oauthResetNote = await resets
                resetNote = webResetNote ?? oauthResetNote
            case .google:
                failure = "Account-specific model history unavailable. Antigravity’s local generation counters do not have a verified per-request account mapping. The limits above come from the signed-in Google account."
            }
        } catch let error as Keychain.AccessError { failure = error.description }
        catch { failure = "Details unavailable. Refresh the account or sign in again." }
    }
}
