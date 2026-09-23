import SwiftUI

/// Keep the data view alive while collapsed, so reopening does not discard the
/// report and move the arrow again after another network round trip.
struct ModelUsageDisclosure: View {
    let account: Account
    let accent: Color
    var preview: UsageDetails? = nil
    @State private var expanded: Bool
    @Environment(\.revealTrackerDetail) private var reveal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(account: Account, accent: Color, preview: UsageDetails? = nil, initiallyExpanded: Bool = false) {
        self.account = account; self.accent = accent; self.preview = preview
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(spacing: 0) {
            BoundedTrackerScroll(maxHeight: 240, expanded: expanded) {
                UsageDetailsView(account: account, accent: accent, preview: preview, active: expanded)
                    .padding(.bottom, 7)
            }
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: ConfigPanelContainer.slideDuration)) {
                    expanded.toggle()
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .foregroundStyle(accent.opacity(0.8))
                    .frame(maxWidth: .infinity).frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(DetailDisclosureStyle(accent: accent))
            .id("model-details-\(account.id.uuidString)")
            .accessibilityIdentifier("model-details-\(account.id.uuidString)")
            .accessibilityLabel(expanded ? "Hide model usage details" : "Show model usage details")
            .accessibilityValue(expanded ? "expanded" : "collapsed")
            .help(expanded ? "Hide model usage details" : "Show model usage details")
        }
        .task(id: expanded) {
            guard expanded else { return }
            // Let the rollout settle, then keep the collapse control in view
            // if this card is near the bottom of the outer account list.
            do { try await Task.sleep(for: .seconds(ConfigPanelContainer.slideDuration)) } catch { return }
            guard !Task.isCancelled else { return }
            reveal("model-details-\(account.id.uuidString)")
        }
    }
}

private struct DetailDisclosureStyle: ButtonStyle {
    let accent: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(accent.opacity(configuration.isPressed ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
    }
}
