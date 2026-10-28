import AppKit
import PurlayTokens
import QuartzCore
import SwiftUI

/// One app-wide appearance change keeps native chrome, sheets and SwiftUI content in the same frame.
struct AppearancePreference: ViewModifier {
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onAppear { AppearanceTransition.apply(appearance, animated: false) }
            .onChange(of: appearance) { _, next in
                AppearanceTransition.apply(next, animated: !reduceMotion)
            }
    }
}

/// A short bitmap crossfade keeps one live view tree while native controls and text resolve the new appearance.
@MainActor
enum AppearanceTransition {
    private static var snapshots: [ObjectIdentifier: AppearanceSnapshot] = [:]

    static func apply(_ preference: AppAppearance, animated: Bool) {
        let app = NSApplication.shared
        let target = preference.native
        guard app.appearance?.name != target?.name else { return }

        let animate = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            // Freeze the current blend before a rapid second selection, so the next fade starts where the eye is.
            for snapshot in snapshots.values { snapshot.freeze() }
        }
        let incoming = animate ? app.windows.compactMap(AppearanceSnapshot.capture) : []
        for snapshot in snapshots.values { snapshot.removeFromSuperview() }
        snapshots.removeAll()
        for snapshot in incoming {
            guard let host = snapshot.host else { continue }
            snapshots[ObjectIdentifier(host)] = snapshot
            host.addSubview(snapshot, positioned: .above, relativeTo: nil)
        }

        app.appearance = target

        // Give AppKit and SwiftUI one main-loop turn to resolve their new appearance beneath the opaque snapshot.
        DispatchQueue.main.async {
            let current = incoming.filter { snapshot in
                guard let host = snapshot.host else { return false }
                return snapshots[ObjectIdentifier(host)] === snapshot
            }
            guard !current.isEmpty else { return }
            for snapshot in current {
                snapshot.host?.layoutSubtreeIfNeeded()
                snapshot.host?.displayIfNeeded()
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.durationStep.seconds
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                for snapshot in current { snapshot.animator().alphaValue = 0 }
            } completionHandler: {
                Task { @MainActor in
                    for snapshot in current {
                        if let host = snapshot.host, snapshots[ObjectIdentifier(host)] === snapshot {
                            snapshots.removeValue(forKey: ObjectIdentifier(host))
                        }
                        snapshot.removeFromSuperview()
                    }
                }
            }
        }
    }
}

/// This surface never takes focus or intercepts clicks; it is discarded as soon as the crossfade ends.
@MainActor
final class AppearanceSnapshot: NSView {
    weak var host: NSView?
    private var bitmap: CGImage?

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() { layer?.contents = bitmap }

    static func capture(_ window: NSWindow) -> AppearanceSnapshot? {
        guard window.isVisible, !window.isMiniaturized, window.styleMask.contains(.titled),
            let host = window.contentView?.superview,
            !host.bounds.isEmpty,
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        else { return nil }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return nil }
        let snapshot = AppearanceSnapshot(frame: host.bounds)
        snapshot.host = host
        snapshot.bitmap = image
        snapshot.autoresizingMask = [.width, .height]
        snapshot.wantsLayer = true
        snapshot.layer?.contentsScale = window.backingScaleFactor
        snapshot.layer?.contentsGravity = .resize
        snapshot.setAccessibilityElement(false)
        snapshot.setAccessibilityHidden(true)
        return snapshot
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func freeze() {
        let opacity = layer?.presentation()?.opacity ?? Float(alphaValue)
        layer?.removeAllAnimations()
        alphaValue = CGFloat(opacity)
    }
}
