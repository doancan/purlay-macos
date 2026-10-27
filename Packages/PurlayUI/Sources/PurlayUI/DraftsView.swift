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
            HStack(spacing: Spacing.space3) {
                Image(systemName: "square.and.pencil").foregroundStyle(Colors.accentText.style)
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    Text("Drafts").font(.title2.bold())
                    Text("Pick up where you left off.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
            }
            .padding(Spacing.space5)
            Divider()
            if channels.isEmpty {
                ContentUnavailableView(
                    "No Unfinished Messages", systemImage: "square.and.pencil",
                    description: Text("Channel drafts are saved automatically on this Mac."))
            } else {
                List(channels, id: \.id) { channel in
                    Button {
                        Task {
                            await model.showChannel(channel.id)
                            dismiss()
                        }
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
