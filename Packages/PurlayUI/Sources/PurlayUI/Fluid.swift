import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

// The small movements that make the window feel alive without asking for attention: a scroller that is there when the pointer
// is, and who is typing. Each one stands still under Reduce Motion.

extension View {
    /// A thin scroller drawn over the content, shown while the pointer is over the scroll view or while it moves, and dragged
    /// like the system's. The system's own is hidden: with "Show scroll bars: Always" it would take a column of its own and
    /// push the content aside each time it came and went.
    func hoverScroller() -> some View { modifier(HoverScroller()) }
}

private struct HoverScroller: ViewModifier {
    @State private var geometry: ScrollGeometry?
    @State private var hovering = false
    @State private var scrolling = false
    @State private var overThumb = false
    @State private var dragFrom: CGFloat?
    @State private var position = ScrollPosition()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scrollIndicators(.never)
            .scrollPosition($position)
            .onScrollGeometryChange(for: ScrollGeometry.self) {
                $0
            } action: { _, new in
                geometry = new
            }
            .onScrollPhaseChange { _, phase in scrolling = phase.isScrolling }
            .onHover { hovering = $0 }
            .overlay(alignment: .topTrailing) { scroller }
    }

    private var shown: Bool { hovering || scrolling || dragFrom != nil }

    @ViewBuilder private var scroller: some View {
        if let metrics {
            Capsule()
                .fill(Colors.inkSubtle.style)
                .frame(
                    width: overThumb || dragFrom != nil
                        ? Spacing.space2 + Stroke.strokeFocus : Spacing.space1 + Stroke.strokeFocus,
                    height: metrics.thumb
                )
                .opacity(shown ? (overThumb || dragFrom != nil ? 0.7 : 0.45) : 0)
                .padding(.trailing, Stroke.strokeFocus)
                .offset(y: metrics.top + metrics.thumbOffset)
                .contentShape(.rect.inset(by: -Spacing.space1))
                .onHover { overThumb = $0 }
                .gesture(drag(metrics))
                .animation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationOverlay), value: shown)
                .animation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationHover), value: overThumb)
                .accessibilityHidden(true)
        }
    }

    private func drag(_ metrics: Metrics) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let from = dragFrom ?? metrics.offset
                if dragFrom == nil { dragFrom = from }
                let moved = metrics.travel > 0 ? value.translation.height * metrics.range / metrics.travel : 0
                position.scrollTo(y: min(max(from + moved, metrics.minOffset), metrics.minOffset + metrics.range))
            }
            .onEnded { _ in dragFrom = nil }
    }

    /// Where the thumb is and how long, from what the scroll view says of itself; nil when everything fits.
    private struct Metrics {
        let top: CGFloat
        let thumb: CGFloat
        let thumbOffset: CGFloat
        let travel: CGFloat
        let range: CGFloat
        let offset: CGFloat
        let minOffset: CGFloat
    }

    private var metrics: Metrics? {
        guard let geometry else { return nil }
        let insets = geometry.contentInsets
        let visible = geometry.containerSize.height - insets.top - insets.bottom
        let range = geometry.contentSize.height - visible
        guard visible > 0, range > 1 else { return nil }
        let track = visible - Spacing.space2
        let thumb = max(Size.sizeDrag, track * visible / geometry.contentSize.height)
        let travel = track - thumb
        let minOffset = -insets.top
        let progress = min(max((geometry.contentOffset.y - minOffset) / range, 0), 1)
        return Metrics(
            top: insets.top + Spacing.space1, thumb: thumb, thumbOffset: travel * progress, travel: travel,
            range: range,
            offset: geometry.contentOffset.y, minOffset: minOffset)
    }
}

/// Who is typing in this channel, just above the box: "Alice is typing…", "Alice and Bob are typing…", or "Several people
/// are typing…". It takes no room when nobody is.
struct TypingLine: View {
    let model: AppModel
    let channel: Uuid
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let names = model.typingNames(in: channel)
        if !names.isEmpty {
            HStack(spacing: Spacing.space1 + Stroke.strokeFocus) {
                TypingDots(animated: !reduceMotion)
                Text(Self.words(names))
                    .typeStyle(Typography.caption)
                    .foregroundStyle(Colors.inkMuted.style)
                    .lineLimit(1)
            }
            .padding(.horizontal, Spacing.space2)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
        }
    }

    static func words(_ names: [String]) -> String {
        switch names.count {
        case 1: String(localized: "\(names[0]) is typing…")
        case 2, 3: String(localized: "\(names.formatted(.list(type: .and))) are typing…")
        default: String(localized: "Several people are typing…")
        }
    }
}

/// Three dots that rise in turn, drawn on the timeline rather than with a timer, so they cost nothing when not on screen.
private struct TypingDots: View {
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated)) { context in
            HStack(spacing: Stroke.strokeFocus + 1) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Colors.inkSubtle.style)
                        .frame(width: Spacing.space1 + 1, height: Spacing.space1 + 1)
                        .offset(y: animated ? lift(index, context.date) : 0)
                }
            }
        }
        .frame(height: Spacing.space3)
        .accessibilityHidden(true)
    }

    private func lift(_ index: Int, _ date: Date) -> CGFloat {
        let phase = date.timeIntervalSinceReferenceDate * 2 * .pi / 1.2 - Double(index) * 0.7
        return -CGFloat(max(0, sin(phase))) * Stroke.strokeFocus * 1.5
    }
}
