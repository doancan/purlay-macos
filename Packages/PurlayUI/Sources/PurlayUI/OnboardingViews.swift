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

/// Waiting for the server or the workspace: the icon and what is happening, never an empty window.
struct CheckingView: View {
    let label: String

    var body: some View {
        OnboardingCard(title: "Purlay", subtitle: label) {
            ProgressView().controlSize(.small)
        }
        .accessibilityElement(children: .combine)
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
                .buttonStyle(.glassProminent)
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
                .buttonStyle(.glassProminent)
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
