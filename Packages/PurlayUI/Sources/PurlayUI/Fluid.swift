import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

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
                    .foregroundStyle(NativePalette.secondary.style)
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
                        .fill(NativePalette.tertiary.style)
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

extension View {
    /// A panel over the window, as Spotlight floats over the desktop: it is dismissed by a click anywhere outside it or by
    /// Escape, never only by a button; the window behind is dimmed a little so the eye goes to the panel.
    func floatingPanel<Panel: View>(isPresented: Binding<Bool>, @ViewBuilder panel: @escaping () -> Panel) -> some View
    {
        modifier(FloatingPanel(isPresented: isPresented, panel: panel))
    }
}

private struct FloatingPanel<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let panel: () -> Panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    ZStack(alignment: .top) {
                        Rectangle()
                            .fill(Colors.scrim.style)
                            .opacity(0.5)
                            .ignoresSafeArea()
                            .contentShape(.rect)
                            .onTapGesture { isPresented = false }
                            .accessibilityLabel(Text("Close"))
                            .accessibilityAddTraits(.isButton)
                            .transition(.opacity)
                        panel()
                            .modifier(ControlSurface())
                            .tokenShadow(Shadows.shadowFloat)
                            .padding(.top, Size.sizeHeader * 2)
                            .onExitCommand { isPresented = false }
                            .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
                            .accessibilityAddTraits(.isModal)
                    }
                }
            }
            .animation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationOverlay), value: isPresented)
    }
}
