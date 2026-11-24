import AppKit
import PurlayKit
import PurlayTokens
import SwiftUI

/// The frame every screen before the workspace shares: the app's own icon, a title and a line under it, and what can be done,
/// on one glass card over the window's material. The first thing a person sees of Purlay looks like the rest of it.
struct OnboardingCard<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Spacing.space16) {
                    identity.frame(width: Size.sizeAttachment)
                    form
                }
                VStack(spacing: Spacing.space6) {
                    appIcon
                    form
                }
            }
            .padding(Spacing.space8)
            .frame(maxWidth: .infinity, minHeight: Size.sizeDialog)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .defaultScrollAnchor(.center)
        .containerBackground(.ultraThinMaterial, for: .window)
    }

    private var appIcon: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable().frame(width: Size.sizeRail * 1.5, height: Size.sizeRail * 1.5)
            .accessibilityHidden(true)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.space6) {
            appIcon
            VStack(alignment: .leading, spacing: Spacing.space3) {
                Text("Good work.\nBetter together.")
                    .font(.system(size: Spacing.space8, weight: .bold)).tracking(-0.7)
                Text("A quieter place for your team's conversations, ideas and decisions.")
                    .typeStyle(Typography.body).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Spacing.space4) {
                identityLine("Conversations that stay in context", image: "bubble.left.and.bubble.right")
                identityLine("Space to focus with Deep Work", image: "moon")
                identityLine("Stay signed in on this Mac", image: "checkmark.shield")
            }
        }
    }

    private func identityLine(_ title: LocalizedStringKey, image: String) -> some View {
        Label(title, systemImage: image).font(.callout).foregroundStyle(.secondary)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Spacing.space6) {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                Text(title).typeStyle(Typography.display).foregroundStyle(NativePalette.ink.style)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).typeStyle(Typography.body).foregroundStyle(NativePalette.secondary.style)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(Spacing.space8)
        .frame(width: Size.sizeDialog - Spacing.space16)
        .background(NativePalette.raised.style, in: .rect(cornerRadius: Radius.radius2xl * 2))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.radius2xl * 2)
                .strokeBorder(NativePalette.border.style, lineWidth: Stroke.strokeHairline)
                .allowsHitTesting(false)
        }
    }
}

/// Waiting for the server or the workspace, which is most of every launch of a signed-in app: the icon, breathing, and nothing of the
/// sign-in page. What is happening is said only if the wait is long enough to be felt, and a quick launch never shows a word.
struct LaunchView: View {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false
    @State private var pulsing = false
    @State private var wordsShown = false

    private static let iconSize: Double = 96

    var body: some View {
        VStack(spacing: Spacing.space8) {
            ZStack {
                ForEach(0..<2, id: \.self) { ring in
                    RoundedRectangle(cornerRadius: Self.iconSize * 0.23, style: .continuous)
                        .strokeBorder(Colors.accent.color.opacity(0.5), lineWidth: Stroke.strokeHairline * 1.5)
                        .frame(width: Self.iconSize, height: Self.iconSize)
                        .scaleEffect(pulsing ? 1.55 : 1)
                        .opacity(pulsing ? 0 : 0.7)
                        .animation(
                            reduceMotion
                                ? nil
                                : .easeOut(duration: 2.2).repeatForever(autoreverses: false).delay(Double(ring) * 1.1),
                            value: pulsing)
                }
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: Self.iconSize, height: Self.iconSize)
                    .scaleEffect(arrived ? 1 : 0.86)
                    .opacity(arrived ? 1 : 0)
                    .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            }
            .accessibilityHidden(true)
            Text(label)
                .typeStyle(Typography.body).foregroundStyle(NativePalette.secondary.style)
                .opacity(wordsShown ? 1 : 0)
                .contentTransition(.opacity)
                .animation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationStep), value: label)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.ultraThinMaterial, for: .window)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .task {
            withAnimation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.78)) { arrived = true }
            pulsing = true
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationStep)) {
                wordsShown = true
            }
        }
    }
}

/// Purlay cannot be reached or used, and why, with the one thing that can be done: try again.
struct ProblemView: View {
    let model: AppModel
    let problem: ServerProblem

    var body: some View {
        let words = Words.problem(problem)
        OnboardingCard(title: LocalizedStringKey(words.title), subtitle: words.detail.isEmpty ? nil : words.detail) {
            VStack(spacing: Spacing.space3) {
                Button(action: retry) {
                    Label("Try Again", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .glassButton(prominent: true)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func retry() {
        Task { await model.connect() }
    }
}

struct SignInView: View {
    let model: AppModel
    let busy: Bool

    var body: some View {
        OnboardingCard(
            title: "Sign In to Purlay",
            subtitle: String(
                localized: "Continue in your browser to sign in securely.")
        ) {
            VStack(spacing: Spacing.space3) {
                ForEach(model.notices) { notice in
                    NoticeBanner(notice: notice) { model.dismiss(notice) }
                }
                Button {
                    Task { await model.signIn() }
                } label: {
                    HStack(spacing: Spacing.space2) {
                        if busy { ProgressView().controlSize(.small) }
                        Text(busy ? "Waiting for the Browser…" : "Sign In with Browser")
                    }
                    .frame(maxWidth: .infinity)
                }
                .glassButton(prominent: true)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
                Label("You stay signed in on this Mac until you sign out.", systemImage: "lock")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
