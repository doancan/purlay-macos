import SwiftUI

/// A single cadence for navigation. Short travel keeps text legible while preserving the direction of a change.
enum NavigationMotion {
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.24, extraBounce: 0)
    }
}

struct PaneTransition: ViewModifier {
    var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: forward ? 18 : -18)),
                    removal: .opacity.combined(with: .offset(x: forward ? -12 : 12))))
    }
}

/// Only the incoming channel is rendered. Keeping a second live feed for an outgoing animation doubles layout and observers.
struct ChannelEntrance: ViewModifier {
    var forward = true
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0.6)
            .offset(x: appeared || reduceMotion ? 0 : forward ? 10 : -10)
            .onAppear {
                withAnimation(NavigationMotion.animation(reduceMotion: reduceMotion)) { appeared = true }
            }
    }
}
