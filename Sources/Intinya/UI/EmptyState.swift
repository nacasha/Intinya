import SwiftUI

/// What a pane shows when it has nothing to show.
///
/// One component, and one rule about where it goes: centred in the pane, always.
/// The five of these had each been placed against whatever happened to be around
/// them — under a heading, 40pt from the top, 60pt from the top, centred in the
/// remaining space — so moving between panes moved the message. Where a
/// placeholder sits is not information, and it should not appear to be.
///
/// Deliberately drawn *instead of* the pane's usual structure rather than inside
/// it. A heading over an empty page is a label for nothing, and it is what
/// pushed these off-centre in the first place.
struct EmptyState: View {
    let systemImage: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)

            Text(title)
                .font(Theme.Font.title)
                .foregroundStyle(.secondary)

            if let detail {
                Text(detail)
                    .font(Theme.Font.body)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Narrow enough that a sentence of explanation wraps into a block under
        // the title rather than running the width of an ultrawide window.
        .frame(maxWidth: 340)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
