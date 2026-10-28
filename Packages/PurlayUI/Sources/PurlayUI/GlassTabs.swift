import PurlayTokens
import SwiftUI

/// A row of tabs on a capsule of glass, the chosen one a raised pill that slides to the next choice rather than jumping. Lighter
/// than the system's segmented control, whose grey track reads heavy on a white inspector.
struct GlassTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> LocalizedStringKey
    /// A symbol beside each title, where the tabs are pages of their own (Settings) rather than views of one thing.
    var image: ((Tab) -> String)? = nil
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                let chosen = tab == selection
                Button {
                    selection = tab
                } label: {
                    label(tab)
                        .font(.callout.weight(chosen ? .semibold : .regular))
                        .foregroundStyle(NativePalette.ink.style)
                        .frame(maxWidth: .infinity, minHeight: Size.sizeControl - Spacing.space1)
                        .background {
                            if chosen {
                                Capsule()
                                    .fill(NativePalette.segmentKnob.style)
                                    .tokenShadow(Shadows.shadowCard)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(Stroke.strokeFocus)
        .modifier(ControlSurface(radius: Radius.radiusPill))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func label(_ tab: Tab) -> some View {
        if let image {
            Label(title(tab), systemImage: image(tab))
        } else {
            Text(title(tab))
        }
    }
}
