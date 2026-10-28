import SwiftUI

struct StatusCardView: View {
    enum Status {
        case starting, active, retrying, failed, done

        var title: String {
            switch self {
            case .starting: "Starting"
            case .active: "Active"
            case .retrying: "Retrying"
            case .failed: "Failed"
            case .done: "Done"
            }
        }

        var symbolName: String {
            switch self {
            case .starting: "clock.fill"
            case .active: "checkmark.circle.fill"
            case .retrying: "arrow.clockwise"
            case .failed: "xmark.circle.fill"
            case .done: "checkmark.seal.fill"
            }
        }

        var color: Color {
            switch self {
            case .starting: .secondary
            case .active: .teal
            case .retrying: .orange
            case .failed: .red
            case .done: .green
            }
        }
    }

    let title: String
    let subtitle: String
    let systemImage: String
    let status: Status

    var body: some View {
        HStack(spacing: DS.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Label(status.title, systemImage: status.symbolName)
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(status.color)
        }
        .padding()
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: DS.cornerRadius)
        )
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    VStack(spacing: 12) {
        StatusCardView(
            title: "Route", subtitle: "Fastest safe route",
            systemImage: "map.fill", status: .active
        )
        StatusCardView(
            title: "Live stream", subtitle: "Reconnecting…",
            systemImage: "video.fill", status: .retrying
        )
    }
    .padding()
}
