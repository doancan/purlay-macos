import PurlayKit
import SwiftUI

/// Asks for the address of the server (M-9): one server at a time.
struct ServerAddressView: View {
    let model: AppModel
    @State private var address = ""

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Connect to your Purlay server").font(.title2.bold())
            TextField("chat.example.com", text: $address)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .autocorrectionDisabled()
                .onSubmit(connect)
            Button("Continue", action: connect)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            ForEach(model.notices) { notice in
                NoticeBanner(notice: notice) { model.dismiss(notice) }.frame(maxWidth: 420)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect() {
        let typed = address
        Task { await model.connect(to: typed) }
    }
}

struct CheckingView: View {
    let label: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(label).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A server this app cannot use, and why, with the two things that can be done: try again, or choose another server.
struct ProblemView: View {
    let model: AppModel
    let problem: ServerProblem

    var body: some View {
        let words = Words.problem(problem)
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 36)).foregroundStyle(.orange)
            Text(words.title).font(.title3.bold())
            if !words.detail.isEmpty { Text(words.detail).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            if let server = model.server {
                Text(server.description).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            HStack {
                Button("Try again") { retry() }.keyboardShortcut(.defaultAction)
                Button("Choose another server") { Task { await model.chooseAnotherServer() } }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        VStack(spacing: 18) {
            Image(systemName: "person.crop.circle").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Sign in to Purlay").font(.title2.bold())
            if let server = model.server {
                Text(server.description).font(.callout.monospaced()).foregroundStyle(.secondary)
            }
            Text("You will sign in in your browser, the same way you do on the web.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 340)
            Button {
                Task { await model.signIn() }
            } label: {
                if busy { ProgressView().controlSize(.small) } else { Text("Sign in with browser") }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(busy)
            Button("Use another server") { Task { await model.chooseAnotherServer() } }.buttonStyle(.link).disabled(
                busy)
            ForEach(model.notices) { notice in
                NoticeBanner(notice: notice) { model.dismiss(notice) }.frame(maxWidth: 440)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
