import SwiftUI
import AppKit

/// The menu bar icon displaying usage at a glance
struct MenuBarIcon: View {
    @ObservedObject var viewModel: UsageViewModel

    var body: some View {
        // Render everything as a single image for reliable menu bar display
        Image(nsImage: createMenuBarImage())
            .id(refreshID) // Force re-render when any value changes
    }

    /// Unique ID that changes when the display should update
    private var refreshID: String {
        let mode = viewModel.displayMode.rawValue
        let pct = Int(viewModel.sessionPercentage)
        let time = viewModel.sessionTimeRemaining ?? ""
        return "\(mode)-\(pct)-\(time)"
    }

    /// Creates the complete menu bar image with gauge and text
    private func createMenuBarImage() -> NSImage {
        let text = buildDisplayText()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

        // Calculate text size
        let textAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = (text as NSString).size(withAttributes: textAttributes)

        // Layout constants
        let gaugeSize: CGFloat = 14
        let spacing: CGFloat = 5
        let padding: CGFloat = 2

        // Total image size
        let totalWidth = padding + gaugeSize + spacing + textSize.width + padding
        let totalHeight = max(gaugeSize, textSize.height) + 4

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight))

        image.lockFocus()

        // Draw circular progress gauge
        let gaugeRect = NSRect(
            x: padding,
            y: (totalHeight - gaugeSize) / 2,
            width: gaugeSize,
            height: gaugeSize
        )
        drawCircularProgress(in: gaugeRect, progress: viewModel.sessionPercentage / 100)

        // Draw text
        let textRect = NSRect(
            x: padding + gaugeSize + spacing,
            y: (totalHeight - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )
        text.draw(in: textRect, withAttributes: textAttributes)

        image.unlockFocus()

        // Don't use template mode so colors are preserved
        image.isTemplate = false

        return image
    }

    /// Builds the display text based on current mode
    private func buildDisplayText() -> String {
        let percentage = "\(Int(viewModel.sessionPercentage))%"

        switch viewModel.displayMode {
        case .minimal:
            return percentage
        case .normal:
            if let time = viewModel.sessionTimeRemaining {
                return "\(percentage) \(time)"
            }
            return percentage
        case .verbose:
            if let resetsAt = viewModel.sessionUsage?.resetsAt,
               let time = TimeFormatter.formatCompactTime(from: resetsAt, verbose: true) {
                return "\(percentage) \(time)"
            }
            return percentage
        }
    }

    /// Draws a circular progress indicator
    private func drawCircularProgress(in rect: NSRect, progress: Double) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - 1.5
        let lineWidth: CGFloat = 2.5

        // Background circle
        NSColor.gray.withAlphaComponent(0.3).setStroke()
        let bgPath = NSBezierPath()
        bgPath.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        bgPath.lineWidth = lineWidth
        bgPath.stroke()

        // Progress arc (fills clockwise from top)
        if progress > 0.001 {
            let progressColor = colorForProgress(progress)
            progressColor.setStroke()

            // Start from top (90°), go clockwise
            let startAngle: CGFloat = 90
            let endAngle: CGFloat = 90 - (CGFloat(min(progress, 1.0)) * 360)

            let progressPath = NSBezierPath()
            progressPath.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: true
            )
            progressPath.lineWidth = lineWidth
            progressPath.lineCapStyle = .round
            progressPath.stroke()
        }
    }

    /// Returns color based on progress level
    private func colorForProgress(_ progress: Double) -> NSColor {
        if progress >= 0.9 {
            return NSColor.systemRed
        } else if progress >= 0.75 {
            return NSColor.systemOrange
        } else {
            return NSColor.systemBlue
        }
    }
}

// MARK: - Preview

#if DEBUG
struct MenuBarIcon_Previews: PreviewProvider {
    static var previews: some View {
        MenuBarIcon(viewModel: UsageViewModel())
            .padding()
    }
}
#endif
