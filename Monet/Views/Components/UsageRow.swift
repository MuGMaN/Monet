import SwiftUI

/// A row displaying a usage metric with title, subtitle, progress bar, and percentage
struct UsageRow: View {
    let title: String
    let subtitle: String
    let percentage: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    if !title.isEmpty {
                        Text(title)
                            .font(.system(.body, weight: .medium))
                            .foregroundColor(.primary)
                    }

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Percentage badge
                Text("\(Int(percentage))%")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(color.opacity(0.12))
                    .cornerRadius(6)
            }

            UsageProgressBar(progress: percentage / 100, color: color)
        }
    }
}

// MARK: - Convenience Initializers

extension UsageRow {
    /// Creates a usage row from a UsageMetric
    init(
        title: String,
        metric: UsageMetric?,
        color: Color,
        subtitleFormatter: (UsageMetric?) -> String
    ) {
        self.title = title
        self.subtitle = subtitleFormatter(metric)
        self.percentage = metric?.utilization ?? 0
        self.color = color
    }

    /// Creates a usage row with adaptive coloring based on usage level
    static func adaptive(
        title: String,
        subtitle: String,
        percentage: Double
    ) -> UsageRow {
        let color: Color
        if percentage < 75 {
            color = .blue
        } else if percentage < 90 {
            color = .orange
        } else {
            color = .red
        }
        return UsageRow(title: title, subtitle: subtitle, percentage: percentage, color: color)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    VStack(spacing: 20) {
        UsageRow(
            title: "Current session",
            subtitle: "Resets in 2:11",
            percentage: 32,
            color: .blue
        )

        Divider()

        UsageRow(
            title: "All models",
            subtitle: "Resets Mon 9:59 PM",
            percentage: 75,
            color: .orange
        )

        Divider()

        UsageRow(
            title: "Sonnet only",
            subtitle: "Resets Tue 3:00 AM",
            percentage: 45,
            color: .teal
        )

        Divider()

        UsageRow(
            title: "Opus only",
            subtitle: "You haven't used Opus yet",
            percentage: 0,
            color: .purple
        )

        Divider()

        UsageRow.adaptive(
            title: "Critical usage",
            subtitle: "Almost at limit!",
            percentage: 95
        )
    }
    .padding()
    .frame(width: 320)
    .background(Color(.windowBackgroundColor))
}
#endif
