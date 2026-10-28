import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

struct DraftsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var channels: [Channel] {
        model.channels.filter {
            $0.state != nil && !model.draft(for: $0.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Drafts", subtitle: "Pick up where you left off.", image: "square.and.pencil") {
                dismiss()
            }
            Divider()
            if channels.isEmpty {
                EmptyState(
                    "No Unfinished Messages", systemImage: "square.and.pencil",
                    description: Text("Channel drafts are saved automatically on this Mac.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(channels, id: \.id) { channel in
                    Button {
                        // The sheet goes at once; the channel opens behind it.
                        dismiss()
                        Task { await model.showChannel(channel.id) }
                    } label: {
                        HStack(alignment: .top, spacing: Spacing.space3) {
                            ChannelEmblem(channel: channel)
                            VStack(alignment: .leading, spacing: Spacing.space2) {
                                Text(Words.channelLabel(channel)).font(.headline)
                                Text(model.draft(for: channel.id)).font(.callout).foregroundStyle(.secondary).lineLimit(
                                    3)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, Spacing.space3).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .frame(width: Size.sizePalette, height: Size.sizePaletteList + Size.sizeHeader)
    }
}
