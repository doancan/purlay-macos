import AppKit
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
    /// For a sheet that only lists things: pressing the window it covers closes it, as it closes a floating panel. A sheet with
    /// something being typed in it is left to its buttons, so a stray press does not lose the words.
    func dismissOnOutsidePress(_ dismiss: @escaping () -> Void) -> some View {
        background { PanelOutsideClick(active: true, panel: .zero, dismiss: dismiss) }
    }

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
    /// Where the panel is in the window, so that a press outside it can be told from one inside.
    @State private var frame: CGRect = .zero

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
                            .padding(.horizontal, Spacing.space4)
                            .padding(.bottom, Spacing.space4)
                            .onExitCommand { isPresented = false }
                            .background {
                                GeometryReader { proxy in
                                    Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, new in
                                        frame = new
                                    }
                                }
                            }
                            .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
                            .accessibilityAddTraits(.isModal)
                    }
                }
            }
            .background { PanelOutsideClick(active: isPresented, panel: frame) { isPresented = false } }
            .animation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationOverlay), value: isPresented)
    }
}

/// While a panel is open, any press outside it closes it, and so does the window losing the keyboard (another window, another app).
/// The dimming behind the panel closes it too, but it covers only the content: the sidebar, the toolbar and the title bar are not
/// under it, and a click there must not be the one that does nothing. The press that closes it is not passed on, as a menu's is not.
struct PanelOutsideClick: NSViewRepresentable {
    let active: Bool
    let panel: CGRect
    let dismiss: () -> Void

    /// Whether a press at `locationInWindow` (origin at the bottom, as AppKit has it) is outside `panel` (origin at the top, as
    /// SwiftUI has it) in a window whose content is `contentHeight` tall. A panel that has no place yet is outside of nothing.
    static func isOutside(locationInWindow: CGPoint, contentHeight: CGFloat, panel: CGRect) -> Bool {
        guard !panel.isEmpty else { return false }
        let point = CGPoint(x: locationInWindow.x, y: contentHeight - locationInWindow.y)
        return !panel.insetBy(dx: -1, dy: -1).contains(point)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAwareView()
        view.moved = { [weak coordinator = context.coordinator] in coordinator?.windowChanged() }
        context.coordinator.view = view
        return view
    }

    /// Tells when it has been put in a window, which is after it is first updated: a sheet's content is made before its window is.
    private final class WindowAwareView: NSView {
        var moved: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            moved?()
        }
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.update(active: active, panel: panel, dismiss: dismiss)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        private var monitor: Any?
        private var resignObserver: (any NSObjectProtocol)?
        private var panel: CGRect = .zero
        private var dismiss: () -> Void = {}

        private var active = false

        func update(active: Bool, panel: CGRect, dismiss: @escaping () -> Void) {
            self.active = active
            self.panel = panel
            self.dismiss = dismiss
            active ? start() : stop()
        }

        func windowChanged() {
            if active { start() } else { stop() }
        }

        private func start() {
            guard monitor == nil, let window = view?.window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] event in
                guard let self, let window = self.view?.window else { return event }
                // A press in another window of the app is the same as leaving this one.
                guard event.window === window, let height = window.contentView?.bounds.height else {
                    MainActor.assumeIsolated { self.dismiss() }
                    return event
                }
                let outside = MainActor.assumeIsolated {
                    PanelOutsideClick.isOutside(
                        locationInWindow: event.locationInWindow, contentHeight: height, panel: self.panel)
                }
                guard outside else { return event }
                MainActor.assumeIsolated { self.dismiss() }
                return nil
            }
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
            monitor = nil
            resignObserver = nil
        }
    }
}
