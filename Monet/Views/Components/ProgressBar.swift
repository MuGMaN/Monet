import SwiftUI

/// A gradient progress bar component
struct UsageProgressBar: View {
    let progress: Double  // 0.0 to 1.0
    let color: Color
    var height: CGFloat = 8
    var cornerRadius: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(.separatorColor).opacity(0.3))

                // Filled portion with gradient
                if progress > 0 {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.8), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geometry.size.width * min(progress, 1.0), cornerRadius * 2))
                        .shadow(color: color.opacity(0.3), radius: 2, x: 0, y: 1)
                        .animation(.easeInOut(duration: 0.4), value: progress)
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Variants

extension UsageProgressBar {
    /// Creates a progress bar with automatic color based on progress level
    static func adaptive(progress: Double, height: CGFloat = 8) -> UsageProgressBar {
        let color: Color
        if progress < 0.75 {
            color = .blue
        } else if progress < 0.90 {
            color = .orange
        } else {
            color = .red
        }
        return UsageProgressBar(progress: progress, color: color, height: height)
    }

    /// Creates a thin progress bar for compact displays
    static func thin(progress: Double, color: Color) -> UsageProgressBar {
        UsageProgressBar(progress: progress, color: color, height: 4, cornerRadius: 2)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    VStack(spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
            Text("Normal (32%)").font(.caption)
            UsageProgressBar(progress: 0.32, color: .blue)
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Warning (78%)").font(.caption)
            UsageProgressBar(progress: 0.78, color: .orange)
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Critical (95%)").font(.caption)
            UsageProgressBar(progress: 0.95, color: .red)
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Sonnet (45%)").font(.caption)
            UsageProgressBar(progress: 0.45, color: .teal)
        }

        VStack(alignment: .leading, spacing: 8) {
            Text("Opus (12%)").font(.caption)
            UsageProgressBar(progress: 0.12, color: .purple)
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text("Adaptive bars").font(.caption)
            UsageProgressBar.adaptive(progress: 0.5)
            UsageProgressBar.adaptive(progress: 0.8)
            UsageProgressBar.adaptive(progress: 0.95)
        }

        Divider()

        VStack(alignment: .leading, spacing: 8) {
            Text("Thin variant").font(.caption)
            UsageProgressBar.thin(progress: 0.6, color: .blue)
        }
    }
    .padding()
    .frame(width: 300)
}
#endif
