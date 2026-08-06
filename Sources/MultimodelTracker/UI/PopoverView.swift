import SwiftUI

/// Deliberately NOT a copy of the reference: that one is a single-account,
/// single-vendor list. This has to carry up to twelve accounts, so the
/// hierarchy is provider → account → pools, with a coloured provider rail
/// doing the work its section headers can't at this density.
struct PopoverView: View {
    @ObservedObject var store: Store
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.35)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Provider.allCases) { provider in
                        let accts = store.accounts(for: provider)
                        if !accts.isEmpty { section(provider, accts) }
                    }
                }
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 460)
            Divider().opacity(0.35)
            footer
        }
        .frame(width: 340)
        // Without this the popover is see-through: NSPopover supplies no
        // material when its content is a plain SwiftUI hierarchy.
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Multimodel Tracker").font(.system(size: 14, weight: .semibold))
            Spacer()
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Text(store.lastRefresh.map(Self.ago) ?? "never")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func section(_ p: Provider, _ accounts: [Account]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(p.displayName.uppercased())
                    .font(.system(size: 10, weight: .bold)).tracking(0.8)
                    .foregroundStyle(p.accent)
                Text("\(accounts.count)/\(Provider.maxAccountsPerProvider)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16)

            ForEach(accounts) { account in
                AccountCard(account: account, accent: p.accent, maxedStyle: store.maxedStyle)
                    .padding(.horizontal, 12)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button("Refresh") { Task { await store.refreshAll() } }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            Button("Accounts…") { NSApp.sendAction(#selector(AppDelegate.openSettings), to: nil, from: nil) }
                .buttonStyle(.plain).font(.system(size: 12))
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    static func ago(_ d: Date) -> String {
        let m = Int(-d.timeIntervalSinceNow / 60)
        return m < 1 ? "just now" : "\(m)m ago"
    }
}

/// One subscription: a coloured rail, the account label, then its pools.
struct AccountCard: View {
    let account: Account
    let accent: Color
    let maxedStyle: MaxedStyle

    /// Nil while the data is fresh enough to trust. The poll is 3 min, so
    /// anything past 10 gets called out rather than shown as current.
    private var staleLabel: String? {
        guard account.error == nil, !account.limits.isEmpty else { return nil }
        guard let seen = account.lastRefreshed else { return "never refreshed" }
        let mins = Int(Date().timeIntervalSince(seen) / 60)
        guard mins >= 10 else { return nil }
        return mins >= 120 ? "stale \(mins / 60)h" : "stale \(mins)m"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent.opacity(0.85)).frame(width: 3)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Text(account.label).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if let plan = account.plan {
                        Text(plan.uppercased())
                            .font(.system(size: 8, weight: .bold)).tracking(0.5)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(accent.opacity(0.16), in: Capsule())
                            .foregroundStyle(accent)
                    }
                    Spacer()
                    // A usage tracker that quietly shows old numbers is worse
                    // than one that shows nothing: a stalled refresh once left
                    // 33% on screen while the account was actually maxed out.
                    if let stale = staleLabel {
                        Text(stale)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Color.orange.opacity(0.14), in: Capsule())
                    }
                }
                if let err = account.error {
                    Text(err).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
                } else if account.limits.isEmpty {
                    Text("No data yet").font(.system(size: 10)).foregroundStyle(.tertiary)
                } else {
                    ForEach(account.limits) {
                        LimitRow(limit: $0, accent: accent, maxedStyle: maxedStyle)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9).padding(.horizontal, 10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct LimitRow: View {
    let limit: UsageLimit
    let accent: Color
    var maxedStyle: MaxedStyle = .flatline

    /// Amber past 75, red past 90 — the bar earns attention rather than
    /// wearing the provider colour the whole way up.
    private var barColor: Color {
        guard let p = limit.percent else { return .secondary.opacity(0.4) }
        if p >= 90 { return .red }
        if p >= 75 { return .orange }
        return accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(limit.label).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if let p = limit.percent {
                    Text("\(Int(p))%").font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                }
                Text(limit.resetText).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let p = limit.percent, p >= 100 {
                MaxedBar(style: maxedStyle)
            } else if limit.percent != nil {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.10))
                        Capsule().fill(barColor)
                            .frame(width: max(2, geo.size.width * limit.fraction))
                    }
                }
                .frame(height: 5)
            }
        }
    }
}
