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
        VStack(spacing: Spacing.space5) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Size.sizeAvatarLg * 2.5, height: Size.sizeAvatarLg * 2.5)
                .accessibilityHidden(true)
            VStack(spacing: Spacing.space2) {
                Text(title)
                    .typeStyle(Typography.display)
                    .foregroundStyle(Colors.ink.style)
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .typeStyle(Typography.body)
                        .foregroundStyle(Colors.inkMuted.style)
                        .multilineTextAlignment(.center)
                }
            }
            content()
        }
        .padding(Spacing.space8)
        .frame(width: Size.sizeDialog)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.radius2xl * 2))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.ultraThinMaterial, for: .window)
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
                TextField("chat.example.com", text: $address)
                    .textFieldStyle(.plain)
                    .typeStyle(Typography.title)
                    .multilineTextAlignment(.center)
                    .padding(Spacing.space3)
                    .background(Colors.surface100.style, in: .rect(cornerRadius: Radius.radiusXl))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.radiusXl)
                            .strokeBorder(focused ? Colors.focusRing.style : Colors.borderSubtle.style)
                    }
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onSubmit(connect)
                Button(action: connect) {
                    Text("Continue").frame(maxWidth: .infinity)
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
                        .foregroundStyle(Colors.inkMuted.style)
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
                localized: "You sign in in your browser, the same way you do on the web, and come back here.")
        ) {
            VStack(spacing: Spacing.space3) {
                if let server = model.server {
                    Label(server.description, systemImage: "server.rack")
                        .typeStyle(Typography.code)
                        .foregroundStyle(Colors.inkMuted.style)
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
