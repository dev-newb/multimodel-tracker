import SwiftUI

/// Fixed-size pages keep Google detail expansion independent of the catalog size.
struct GoogleQuotaDetailsView: View {
    let report: UsageDetails
    let accent: Color
    @AppStorage("mmt.googleDetailsMode") private var mode = "pools"
    @State private var modelPage = 0
    @State private var poolPage = 0
    private let pageSize = 3
    private var groups: [GoogleQuotaGroup] { report.googleGroups ?? [] }
    private var modelPages: Int { max(1, (report.rows.count + pageSize - 1) / pageSize) }
    private var poolPages: Int { max(groups.reduce(0) { $0 + max(1, ($1.rows.count + pageSize - 1) / pageSize) }, 1) }
    // A new provider group with more windows must remain accessible without scrolling.
    private var poolSlices: [(group: GoogleQuotaGroup, rows: [ModelUsageDetail])] {
        groups.flatMap { group in
            stride(from: 0, to: max(group.rows.count, 1), by: pageSize).map { start in
                (group, Array(group.rows.dropFirst(start).prefix(pageSize)))
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Google detail view", selection: $mode) {
                Text("Quota pools").tag("pools")
                Text("Models").tag("models")
            }.pickerStyle(.segmented).controlSize(.small).labelsHidden()
            VStack(alignment: .leading, spacing: 7) {
                if mode == "models" {
                    Text("Reported model quotas · \(report.rows.count)").font(.system(size: 10, weight: .semibold))
                    ForEach(Array(report.rows.dropFirst(min(modelPage, modelPages - 1) * pageSize).prefix(pageSize))) { row in
                        quotaRow(row)
                    }
                    if report.rows.isEmpty { message(report.emptyMessage) }
                } else if !poolSlices.isEmpty {
                    let slice = poolSlices[min(poolPage, poolPages - 1)]
                    Text(slice.group.title).font(.system(size: 10, weight: .semibold))
                    ForEach(slice.rows) { row in quotaRow(row) }
                    message(slice.group.description)
                } else {
                    message(report.groupFailure ?? "Google has not reported shared quota pools.")
                }
                Spacer(minLength: 0)
            }.frame(height: 150, alignment: .top)
            HStack {
                let pages = mode == "models" ? modelPages : poolPages
                let page = min(mode == "models" ? modelPage : poolPage, pages - 1)
                Spacer()
                PagerArrow(direction: .left, label: "Previous Google detail page") { movePage(-1, count: pages) }
                    .disabled(pages < 2)
                Text("\(page + 1) / \(pages)").font(.system(size: 10)).monospacedDigit()
                PagerArrow(direction: .right, label: "Next Google detail page") { movePage(1, count: pages) }
                    .disabled(pages < 2)
                Spacer()
            }
            message(mode == "models" ? report.note : "Quota used · models in each pool share these limits.")
        }
    }
    private func movePage(_ step: Int, count: Int) {
        if mode == "models" { modelPage = (min(modelPage, count - 1) + step + count) % count }
        else { poolPage = (min(poolPage, count - 1) + step + count) % count }
    }
    private func message(_ text: String) -> some View {
        Text(text).font(.system(size: 9)).foregroundStyle(.secondary)
            .lineLimit(2).help(text).fixedSize(horizontal: false, vertical: true)
    }
    private func quotaRow(_ row: ModelUsageDetail) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(row.model).lineLimit(1).help(row.model + "\n" + row.id)
                Spacer(minLength: 4)
                Text(String(format: "%.0f%%", row.value)).monospacedDigit()
            }.font(.system(size: 10))
            GeometryReader { g in
                Capsule().fill(accent.opacity(0.12)).overlay(alignment: .leading) {
                    Capsule().fill(accent).frame(width: g.size.width * min(max(row.value / 100, 0), 1))
                }
            }.frame(height: 4)
            if let caption = row.caption { Text(caption).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).help(caption) }
        }
    }
}

/// A measured disclosure with no scroll view at all. The child provides paging.
struct TrackerDisclosureClip<Content: View>: View {
    let expanded: Bool
    @ViewBuilder var content: () -> Content
    @State private var height: CGFloat = 1
    var body: some View {
        content().fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.onAppear { height = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, size in height = size }
            })
            .frame(height: expanded ? height : 0, alignment: .top).clipped()
            .allowsHitTesting(expanded).accessibilityHidden(!expanded)
    }
}
