import PurlayContract
import PurlayKit
import SwiftUI

struct UnresolvedPageView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(
                    "Channel",
                    selection: Binding(
                        get: { model.unresolvedChannelID },
                        set: { channel in Task { await model.setUnresolvedChannel(channel) } })
                ) {
                    Text("All conversations").tag(nil as Uuid?)
                    ForEach(model.channels, id: \.id) { channel in
                        Text(Words.channelLabel(channel)).tag(Optional(channel.id))
                    }
                }
                .frame(maxWidth: 320)
                Picker(
                    "Show",
                    selection: Binding(
                        get: { model.unresolvedFilter },
                        set: { filter in Task { await model.setUnresolvedFilter(filter) } })
                ) {
                    Text("All").tag(UnresolvedFilter.all)
                    Text("Unanswered").tag(UnresolvedFilter.unanswered)
                    Text("Assigned to Me").tag(UnresolvedFilter.assignedToMe)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.loadUnresolved() } }
                    .disabled(model.unresolvedLoading)
            }
            .padding()
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Open Topics")
        .navigationSubtitle("Conversations waiting to be resolved")
    }

    @ViewBuilder private var content: some View {
        if model.unresolvedLoading && model.unresolvedItems.isEmpty {
            ProgressView("Loading open topics…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.unresolvedFailed && model.unresolvedItems.isEmpty {
            ContentUnavailableView {
                Label("Could Not Load Open Topics", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { Task { await model.loadUnresolved() } }
            }
        } else if model.unresolvedItems.isEmpty {
            ContentUnavailableView(
                "No Open Topics", systemImage: "checkmark.bubble",
                description: Text("Unresolved conversations will appear here."))
        } else {
            List {
                ForEach(model.unresolvedItems, id: \.id) { message in
                    HStack(alignment: .top, spacing: 16) {
                        Button {
                            Task { await model.openUnresolvedThread(message) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(
                                        model.chat.channels[message.channelId].map(Words.channelLabel) ?? "Conversation"
                                    )
                                    .font(.caption.bold())
                                    Text(message.webhookName ?? message.sender?.displayName ?? "Purlay").font(.caption)
                                    Spacer()
                                    Text(message.createdAt.date, style: .date).font(.caption)
                                }
                                .foregroundStyle(.secondary)
                                Text(message.content).lineLimit(4)
                                HStack(spacing: 6) {
                                    if let question = message.questionState { QuestionMarker(state: question) }
                                    Text("\(message.thread?.replyCount ?? 0) replies").font(.caption).foregroundStyle(
                                        .secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button("Resolve", systemImage: "checkmark.circle") {
                            Task { await model.resolveUnresolved(message) }
                        }
                        .buttonStyle(.borderless)
                        // A question nobody has replied to has nothing to resolve yet (D-204).
                        .disabled(
                            model.unresolvedUpdating.contains(message.id) || (message.thread?.replyCount ?? 0) == 0)
                    }
                    .padding(.vertical, 8)
                }
                if model.unresolvedHasMore {
                    Button(model.unresolvedFailed ? "Try Loading More Again" : "Load More") {
                        Task { await model.loadMoreUnresolved() }
                    }
                    .disabled(model.unresolvedLoading)
                }
                if model.unresolvedLoading { ProgressView() }
            }
            .listStyle(.inset)
        }
    }
}
