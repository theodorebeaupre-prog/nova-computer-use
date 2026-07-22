import SwiftUI

private struct AuroraOrbit: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                if reduceMotion {
                    border(rotation: .zero).opacity(0.82)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        border(rotation: .degrees(time.truncatingRemainder(dividingBy: 12) * 30))
                            .shadow(color: .purple.opacity(0.22 + 0.12 * sin(time * 1.2)), radius: 18)
                    }
                }
            }
    }

    private func border(rotation: Angle) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .stroke(
                AngularGradient(colors: [.cyan, .indigo, .purple, .pink, .orange, .cyan], center: .center, angle: rotation),
                lineWidth: 1.5
            )
    }
}

extension View {
    func novaOrbit(cornerRadius: CGFloat) -> some View {
        modifier(AuroraOrbit(cornerRadius: cornerRadius))
    }
}
