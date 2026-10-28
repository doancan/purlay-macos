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
                identityLine("Your workspace, on your server", image: "server.rack")
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
        .modifier(ControlSurface(radius: Radius.radius2xl * 2))
    }
}

/// Asks for the address of the server (M-9): one server at a time.
struct ServerAddressView: View {
    let model: AppModel
    @State private var address = ""
    @FocusState private var focused: Bool

    var body: some View {
        OnboardingCard(
            title: "Welcome to Purlay",
            subtitle: String(localized: "Enter the address of your team's Purlay server.")
        ) {
            VStack(spacing: Spacing.space3) {
                Text("Server address").font(.callout.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                TextField("chat.example.com", text: $address)
                    .textFieldStyle(.plain)
                    .typeStyle(Typography.title)
                    .padding(Spacing.space3)
                    .accessibilityLabel("Server address")
                    .background(NativePalette.raised.style, in: .rect(cornerRadius: Radius.radiusXl))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.radiusXl)
                            .strokeBorder(focused ? Colors.focusRing.style : NativePalette.border.style)
                    }
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(connect)
                Button(action: connect) {
                    Label("Connect", systemImage: "arrow.right").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                ForEach(model.notices) { notice in
                    NoticeBanner(notice: notice) { model.dismiss(notice) }
                }
            }
        }
        .onAppear { focused = true }
    }

    private func connect() {
        let typed = address
        Task { await model.connect(to: typed) }
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

/// A server this app cannot use, and why, with the two things that can be done: try again, or choose another server.
struct ProblemView: View {
    let model: AppModel
    let problem: ServerProblem

    var body: some View {
        let words = Words.problem(problem)
        OnboardingCard(title: LocalizedStringKey(words.title), subtitle: words.detail.isEmpty ? nil : words.detail) {
            VStack(spacing: Spacing.space3) {
                if let server = model.server {
                    Label(server.description, systemImage: "server.rack")
                        .typeStyle(Typography.code)
                        .foregroundStyle(NativePalette.secondary.style)
                }
                HStack(spacing: Spacing.space2) {
                    Button("Choose Another Server") { Task { await model.chooseAnotherServer() } }
                        .buttonStyle(.glass)
                    Button("Try Again", action: retry)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
        }
    }

    private func retry() {
        guard let server = model.server else { return }
        Task { await model.connect(to: server.description) }
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
                if let server = model.server {
                    Label(server.description, systemImage: "server.rack")
                        .typeStyle(Typography.code)
                        .foregroundStyle(NativePalette.secondary.style)
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
                Button("Use Another Server") { Task { await model.chooseAnotherServer() } }
                    .buttonStyle(.link)
                    .disabled(busy)
                ForEach(model.notices) { notice in
                    NoticeBanner(notice: notice) { model.dismiss(notice) }
                }
            }
        }
    }
}
