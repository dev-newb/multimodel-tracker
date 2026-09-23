import SwiftUI

@MainActor
struct UsageDetailsView: View {
    let account: Account
    let accent: Color
    var preview: UsageDetails? = nil
    @State private var details: UsageDetails?
    @State private var tokenDetails: UsageDetails?
    @State private var failure: String?
    @State private var loading = true
    @State private var refreshing = false
    @ObservedObject private var telemetry = ClaudeTelemetry.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            if loading && preview == nil { ProgressView().controlSize(.small) }
            if let report = preview ?? details { reportView(report) }
            if let tokenDetails { reportView(tokenDetails) }
            if let failure { Text(failure).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if account.provider == .anthropic {
                Text(telemetry.status).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !telemetry.enabled {
                    Button("Enable local Claude Code collection") { telemetry.enable() }.controlSize(.small)
                } else {
                    Button("Stop local collection") { telemetry.disable() }.font(.system(size: 10)).buttonStyle(.plain)
                }
            }
            if !loading {
                Button("Refresh details") { Task { await refresh() } }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(accent)
            }
        }
        .task(id: "\(account.id)-\(account.provider == .anthropic ? account.lastRefreshed?.timeIntervalSince1970 ?? 0 : 0)") {
            guard preview == nil else { return }
            repeat {
                await refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            } while !Task.isCancelled
        }
    }

    private func reportView(_ report: UsageDetails) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(report.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(report.rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.model).lineLimit(1).help(row.model)
                        Spacer(minLength: 4)
                        Text(value(row.value, unit: report.unit)).monospacedDigit()
                    }.font(.system(size: 10))
                    GeometryReader { g in
                        Capsule().fill(accent.opacity(0.12))
                            .overlay(alignment: .leading) {
                                Capsule().fill(accent).frame(width: g.size.width * fraction(row.value, report: report))
                            }
                    }.frame(height: 4)
                    if let caption = row.caption { Text(caption).font(.system(size: 9)).foregroundStyle(.secondary) }
                }
            }
            if report.rows.isEmpty { Text(report.emptyMessage).font(.system(size: 10)).foregroundStyle(.secondary) }
            Text(report.note).font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func fraction(_ value: Double, report: UsageDetails) -> Double {
        let maxValue = report.unit == "quotaPercent" ? 100 : max(report.rows.map(\.value).max() ?? 1, 1)
        return min(max(value / maxValue, 0), 1)
    }
    private func value(_ n: Double, unit: String) -> String {
        if unit == "quotaPercent" { return String(format: "%.0f%%", n) }
        if unit == "percent" { return String(format: "%.2f pp", n) }
        if unit == "credits" { return String(format: "%.2f credits", n) }
        return n.formatted(.number.notation(.compactName)) + " tokens"
    }
    private func refresh() async {
        guard !Task.isCancelled, !refreshing else { return }
        refreshing = true; loading = true; failure = nil
        defer { loading = false; refreshing = false }
        do {
            let result = try await AccountUsageDetails.fetch(account)
            guard !Task.isCancelled else { return }
            details = result.primary; tokenDetails = result.tokens; failure = result.warning
        } catch is CancellationError { }
        catch let error as Keychain.AccessError { failure = error.description }
        catch let error as AdapterError { failure = "Details: \(error.description)" + (details == nil ? "" : ". Showing the previous reading.") }
        catch { failure = "Details: \(error.localizedDescription)" + (details == nil ? "" : ". Showing the previous reading.") }
    }
}
