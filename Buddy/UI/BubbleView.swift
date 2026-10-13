import SwiftUI

@Observable
final class BubbleState {
    enum Phase: Equatable {
        /// Words heard so far while fn⌃ is held ("" before the first word).
        case listening(String)
        case thinking
        case answer(Explanation)
        case error(String)
    }

    /// A question typed or spoken into the bubble after the first answer ("" for a notice with no question).
    struct FollowUp: Equatable, Identifiable {
        enum Answer: Equatable {
            case thinking
            case text(String)
            case error(String)
        }

        let id: Int
        let question: String
        var answer: Answer = .thinking
    }

    var phase: Phase = .thinking
    /// The spoken question the answer replies to; nil when only a circle was drawn.
    var question: String?
    var followUps: [FollowUp] = []
    var draft = ""
    /// A spoken follow-up is being heard: the input box shows the live words.
    var isListening = false
    var isVisible = false
    /// Flipped to the left / above the cursor near screen edges.
    var placeLeft = false
    var placeAbove = false

    var isAsking: Bool { followUps.last?.answer == .thinking }
}

/// The black message cloud that grows out next to the cursor.
struct BubbleView: View {
    @Bindable var state: BubbleState
    /// Called with the follow-up typed into the input box.
    let onAsk: (String) -> Void
    /// Called while the bubble is dragged (`true` when the drag ends), to move the panel.
    let onDrag: (_ ended: Bool) -> Void
    let onClose: () -> Void
    /// The visible bubble's frame inside the panel (top-left origin), so only it takes clicks.
    let onBubbleFrame: (CGRect) -> Void

    @FocusState private var isInputFocused: Bool

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
                    .gesture(
                        DragGesture(minimumDistance: 3)
                            .onChanged { _ in onDrag(false) }
                            .onEnded { _ in onDrag(true) }
                    )
                    .onExitCommand(perform: onClose)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onBubbleFrame($0) }
                    .transition(.scale(scale: 0.03, anchor: anchor).combined(with: .opacity))
            }
        }
        .frame(width: BubbleController.panelSize.width, height: BubbleController.panelSize.height)
        .animation(.spring(duration: 0.3), value: state.isVisible)
        .animation(.spring(duration: 0.3), value: state.phase)
        .animation(.spring(duration: 0.3), value: state.followUps)
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
        case .listening(let words):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                micIcon
                Text(words.isEmpty ? "Listening…" : words)
                    .font(.callout)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: 300, alignment: .leading)

        case .thinking:
            thinking
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

        case .answer(let explanation):
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(explanation.title).font(.headline)
                    Spacer(minLength: 8)
                    closeButton
                }
                // Short threads take only the space they need; long ones scroll inside the panel.
                ViewThatFits(in: .vertical) {
                    thread(explanation)
                    ScrollView { thread(explanation) }
                        .defaultScrollAnchor(.bottom)
                }
                input
            }
            .padding(12)
            .frame(width: 300, alignment: .leading)

        case .error(let message):
            HStack(alignment: .firstTextBaseline) {
                Text(message)
                    .font(.callout)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                closeButton
            }
            .padding(12)
            .frame(width: 300, alignment: .leading)
        }
    }

    private var thinking: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking…").font(.callout)
        }
    }

    private var micIcon: some View {
        Image(systemName: "mic.fill")
            .font(.callout)
            .foregroundStyle(Color(nsColor: BuddyColors.stroke))
            .symbolEffect(.pulse)
    }

    private func thread(_ explanation: Explanation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                if let question = state.question {
                    Text(question)
                        .font(.callout)
                        .foregroundStyle(Color.white.opacity(0.6))
                }
                Text(explanation.what).font(.callout)
            }
            ForEach(state.followUps) { followUp in
                VStack(alignment: .leading, spacing: 4) {
                    if !followUp.question.isEmpty {
                        Text(followUp.question)
                            .font(.callout)
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    switch followUp.answer {
                    case .thinking:
                        thinking
                    case .text(let text):
                        Text(text).font(.callout)
                    case .error(let message):
                        Text(message).font(.callout).foregroundStyle(Color.red)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close")
    }

    private var canSend: Bool {
        !state.isAsking && !state.isListening && !state.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var input: some View {
        HStack(spacing: 6) {
            TextField("Ask a follow-up…", text: $state.draft)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($isInputFocused)
                .onSubmit { if canSend { onAsk(state.draft) } }
            if state.isListening {
                micIcon.font(.title3)
            } else {
                Button {
                    onAsk(state.draft)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(canSend ? Color.white : Color.white.opacity(0.3))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.12))
        )
        .onAppear { isInputFocused = true }
    }
}
