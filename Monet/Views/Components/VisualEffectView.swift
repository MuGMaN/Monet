import SwiftUI
import AppKit

/// A SwiftUI wrapper for NSVisualEffectView to create blur/vibrancy effects
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State

    init(
        material: NSVisualEffectView.Material = .popover,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    ZStack {
        LinearGradient(
            colors: [.blue, .purple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )

        VisualEffectView(material: .popover)
            .frame(width: 300, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                Text("Blur Effect")
                    .font(.title)
                    .foregroundColor(.primary)
            }
    }
    .frame(width: 400, height: 300)
}
#endif
