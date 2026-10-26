import SwiftUI

/// The empty window of the first build; the sign-in and the shell replace it in M1.
struct RootView: View {
    var body: some View {
        ContentUnavailableView("Purlay", systemImage: "bubble.left.and.bubble.right")
            .frame(minWidth: 480, minHeight: 320)
    }
}
