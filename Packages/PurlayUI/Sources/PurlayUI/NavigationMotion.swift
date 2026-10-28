import PurlayTokens
import SwiftUI

/// A single cadence for navigation. Short travel keeps text legible while preserving the direction of a change.
enum NavigationMotion {
    static func animation(reduceMotion: Bool) -> Animation {
        reduceMotion
            ? Motion.easingStandard.animation(Motion.durationHover)
            : .smooth(duration: Motion.durationStep.seconds + Motion.durationBar.seconds / 3, extraBounce: 0)
    }
}

struct PaneTransition: ViewModifier {
    var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var direction

    func body(content: Content) -> some View {
        // "Forward" is towards the trailing edge, which is the left in a right-to-left language.
        let sign: Double = (forward ? 1 : -1) * (direction == .rightToLeft ? -1 : 1)
        return content.transition(
            reduceMotion
                ? .opacity
                : .asymmetric(
                    insertion: .opacity.combined(with: .offset(x: sign * (Spacing.space4 + Stroke.strokeFocus))),
                    removal: .opacity.combined(with: .offset(x: -sign * Spacing.space3))))
    }
}

/// Only the incoming channel is rendered. Keeping a second live feed for an outgoing animation doubles layout and observers.
struct ChannelEntrance: ViewModifier {
    var forward = true
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var direction

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0.6)
            .offset(
                x: appeared || reduceMotion
                    ? 0
                    : (forward ? 1 : -1) * (direction == .rightToLeft ? -1 : 1) * (Spacing.space2 + Stroke.strokeFocus)
            )
            .onAppear {
                withAnimation(NavigationMotion.animation(reduceMotion: reduceMotion)) { appeared = true }
            }
    }
}
