import PurlayContract
import PurlayKit
import SwiftUI

/// A thread, beside the channel it is in (`UX.md` §4.2): its root and where it stands, its replies, and a box to answer in. One thread at
/// a time. Escape closes it.
struct ThreadPanel: View {
    let model: AppModel

    var body: some View {
        if let thread = model.thread {
            VStack(spacing: 0) {
                Header(model: model, thread: thread)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if let root = model.threadRoot {
                                MessageRow(message: root, model: model, inThread: true)
                                Status(model: model, root: root, replies: thread.replies.count)
                            }
                            if !thread.isLoaded {
                                ProgressView().frame(maxWidth: .infinity).padding(24)
                            } else {
                                ForEach(thread.replies, id: \.id) { reply in
                                    MessageRow(message: reply, model: model, inThread: true).id(reply.id)
                                }
                            }
                            ForEach(model.threadPending) { pending in
                                PendingRow(
                                    pending: pending, retry: { model.retry(pending.id) },
                                    discard: { model.discard(pending.id) }
                                )
                                .id("pending-" + pending.id.value)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                    }
                    .onChange(of: thread.replies.last?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    .onChange(of: model.threadPending.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
                Divider()
                ComposerView(
                    model: model, channel: thread.channel, parent: thread.root, placeholder: String(localized: "Reply…")
                )
                .id(thread.root)
            }
            .frame(width: 440)
            .background(.background)
            .onExitCommand { model.closeThread() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Thread")
        }
    }
}

private struct Header: View {
    let model: AppModel
    let thread: ThreadWindow

    var body: some View {
        HStack(spacing: 8) {
            Text("Thread · \(channelName)").font(.headline).lineLimit(1)
            Spacer()
            followButton
            Button {
                model.closeThread()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close  ⎋")
            .accessibilityLabel("Close thread")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var channelName: String {
        model.chat.channels[thread.channel].map(Words.channelLabel) ?? ""
    }

    /// A toggle with one name, pressed while the person is told of new replies. Until the state is read it is there and disabled, so the
    /// header does not move; when it could not be read, pressing it reads it again.
    @ViewBuilder
    private var followButton: some View {
        switch model.threadFollow {
        case .known(let following):
            Button {
                Task { await model.setFollowing(!following) }
            } label: {
                Image(systemName: following ? "bell.fill" : "bell.slash")
            }
            .buttonStyle(.borderless)
            .help(following ? "Turn off notifications for replies" : "Get notified about new replies")
            .accessibilityLabel(following ? "Following" : "Not following")
            .accessibilityAddTraits(following ? .isSelected : [])
        case .reading:
            Button {
            } label: {
                Image(systemName: "bell")
            }.buttonStyle(.borderless).disabled(true).help("Reading…")
        case .failed:
            Button {
                Task { await model.setFollowing(true) }
            } label: {
                Image(systemName: "bell.badge.slash")
            }
            .buttonStyle(.borderless)
            .help("Could not read whether you follow this thread. Press to follow it.")
        }
    }
}

/// Where the thread stands, and the one control that changes it, open to resolved and back.
private struct Status: View {
    let model: AppModel
    let root: Message
    let replies: Int

    var body: some View {
        let resolved = root.thread?.resolvedAt != nil
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if resolved, let by = root.thread?.resolvedBy {
                    Label("Resolved by \(by.displayName)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Label("Open", systemImage: "circle")
                }
                Spacer()
                Button(resolved ? "Reopen" : "Resolve") {
                    Task { _ = resolved ? await model.reopenThread() : await model.resolveThread() }
                }
                .controlSize(.small)
            }
            .font(.callout)
            HStack {
                VStack { Divider() }
                Text("\(replies) replies").font(.caption).foregroundStyle(.secondary)
                VStack { Divider() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
