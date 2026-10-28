import SwiftUI

struct CopyFeedbackButton: View {
    let accessibilityLabel: String
    var isRevealed = true
    let action: () -> Bool

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?
    @Environment(\.reduceAnimations) private var reduceAnimations

    var body: some View {
        Button {
            guard action() else { return }

            withAnimation(Motion.spring) { copied = true }
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.4))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .symbolEffect(.bounce, value: reduceAnimations ? false : copied)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-6)
        .opacity(isRevealed || copied ? 1 : 0)
        .allowsHitTesting(isRevealed || copied)
        .animation(.easeOut(duration: 0.12), value: isRevealed)
        .accessibilityLabel(accessibilityLabel)
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }
}
