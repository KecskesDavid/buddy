import SwiftUI

@Observable
final class BubbleState {
    enum Phase: Equatable {
        case thinking
        case answer(Explanation)
        case error(String)
    }

    var phase: Phase = .thinking
    var isVisible = false
    /// Flipped to the left / above the cursor near screen edges.
    var placeLeft = false
    var placeAbove = false
}

/// The black message cloud that grows out next to the cursor.
struct BubbleView: View {
    let state: BubbleState

    private var alignment: Alignment {
        switch (state.placeLeft, state.placeAbove) {
        case (false, false): .topLeading
        case (true, false): .topTrailing
        case (false, true): .bottomLeading
        case (true, true): .bottomTrailing
        }
    }

    private var anchor: UnitPoint {
        switch (state.placeLeft, state.placeAbove) {
        case (false, false): .topLeading
        case (true, false): .topTrailing
        case (false, true): .bottomLeading
        case (true, true): .bottomTrailing
        }
    }

    var body: some View {
        ZStack(alignment: alignment) {
            Color.clear
            if state.isVisible {
                bubble
                    .transition(.scale(scale: 0.03, anchor: anchor).combined(with: .opacity))
            }
        }
        .frame(width: BubbleController.panelSize.width, height: BubbleController.panelSize.height)
        .animation(.spring(duration: 0.3), value: state.isVisible)
        .animation(.spring(duration: 0.3), value: state.phase)
        .environment(\.colorScheme, .dark)
    }

    private var bubble: some View {
        content
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .thinking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Thinking…").font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

        case .answer(let explanation):
            VStack(alignment: .leading, spacing: 6) {
                Text(explanation.title).font(.headline)
                Text(explanation.what).font(.callout)
                ForEach(Array(explanation.how.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(line)
                    }
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.8))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(width: 300, alignment: .leading)

        case .error(let message):
            Text(message)
                .font(.callout)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 300, alignment: .leading)
        }
    }
}
