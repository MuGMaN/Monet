import SwiftUI

/// A circular progress indicator for the menu bar
struct CircularProgress: View {
    let progress: Double  // 0.0 to 1.0
    var lineWidth: CGFloat = 2
    var backgroundColor: Color = Color.gray.opacity(0.3)

    var body: some View {
        ZStack {
            // Background circle
            Circle()
                .stroke(backgroundColor, lineWidth: lineWidth)

            // Progress arc
            Circle()
                .trim(from: 0, to: min(progress, 1.0))
                .stroke(
                    progressColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: progress)
        }
    }

    /// Color based on progress level
    private var progressColor: Color {
        if progress < 0.75 {
            return .blue
        } else if progress < 0.90 {
            return .orange
        } else {
            return .red
        }
    }
}

// MARK: - Menu Bar Specific Variant

extension CircularProgress {
    /// Creates a circular progress optimized for menu bar display
    static func menuBar(progress: Double) -> some View {
        CircularProgress(progress: progress, lineWidth: 2)
            .frame(width: 14, height: 14)
    }

    /// Creates a larger circular progress for panel display
    static func panel(progress: Double, color: Color) -> some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: 4)

            Circle()
                .trim(from: 0, to: min(progress, 1.0))
                .stroke(
                    color,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: progress)

            Text("\(Int(progress * 100))%")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(color)
        }
        .frame(width: 44, height: 44)
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    HStack(spacing: 24) {
        VStack(spacing: 8) {
            CircularProgress(progress: 0.25)
                .frame(width: 40, height: 40)
            Text("25%")
                .font(.caption)
        }

        VStack(spacing: 8) {
            CircularProgress(progress: 0.50)
                .frame(width: 40, height: 40)
            Text("50%")
                .font(.caption)
        }

        VStack(spacing: 8) {
            CircularProgress(progress: 0.75)
                .frame(width: 40, height: 40)
            Text("75%")
                .font(.caption)
        }

        VStack(spacing: 8) {
            CircularProgress(progress: 0.95)
                .frame(width: 40, height: 40)
            Text("95%")
                .font(.caption)
        }
    }
    .padding()
}
#endif
