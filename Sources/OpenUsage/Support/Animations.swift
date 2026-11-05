import SwiftUI

enum Motion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.80)
    static let modeSwitch = Animation.easeInOut(duration: 0.18)
    /// AppKit's default animation pace, for screen slides, page pushes, and the segment thumb.
    static let navigation = Animation.easeInOut(duration: 0.25)

    /// The single transaction policy behind Reduce Motion. `disablesAnimations` prevents inner
    /// `.animation` modifiers from restoring motion after this root policy clears an explicit animation.
    static func applyReduction(to transaction: inout Transaction, enabled: Bool) {
        guard enabled else { return }
        transaction.animation = nil
        transaction.disablesAnimations = true
    }
}

private struct ReduceAnimationsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var reduceAnimations: Bool {
        get { self[ReduceAnimationsKey.self] }
        set { self[ReduceAnimationsKey.self] = newValue }
    }
}

extension View {
    func reduceAnimationsWhenRequested() -> some View {
        modifier(ReduceAnimationsModifier())
    }

    func animationReduction(_ enabled: Bool) -> some View {
        modifier(AnimationReductionModifier(enabled: enabled))
    }
}

private struct ReduceAnimationsModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func body(content: Content) -> some View {
        content.animationReduction(systemReduceMotion)
    }
}

private struct AnimationReductionModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.reduceAnimations, enabled)
            .transaction { transaction in
                Motion.applyReduction(to: &transaction, enabled: enabled)
            }
    }
}

struct MotionAwareProgressView: View {
    var controlSize: ControlSize = .small

    @Environment(\.reduceAnimations) private var reduceAnimations

    @ViewBuilder
    var body: some View {
        if reduceAnimations {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 12)
        } else {
            ProgressView()
                .controlSize(controlSize)
        }
    }
}
