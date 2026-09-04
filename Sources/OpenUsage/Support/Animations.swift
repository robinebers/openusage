import SwiftUI

/// Shared motion vocabulary so every transition feels consistent and "Apple-native".
enum Motion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.80)
    static let modeSwitch = Animation.easeInOut(duration: 0.18)

    /// The single transaction policy behind Reduce Animations. `disablesAnimations` prevents inner
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
    /// Applies the app preference at the popover root. The transaction catches explicit and implicit
    /// SwiftUI animations; the environment value also reaches the time-driven easter-egg gate. macOS
    /// Reduce Motion remains authoritative even when the app toggle is off.
    func reduceAnimationsWhenRequested() -> some View {
        modifier(ReduceAnimationsModifier())
    }

    /// Applies an already-resolved motion policy. Separate SwiftUI hosts (for example AppKit-owned
    /// hover popovers) use this to receive the same environment value and transaction clamp as the
    /// dashboard root.
    func animationReduction(_ enabled: Bool) -> some View {
        modifier(AnimationReductionModifier(enabled: enabled))
    }

    /// The macOS "denied" idiom: a brief horizontal shake, like the login window on a wrong
    /// password. Increment `trigger` to play one shake; repeats re-shake so a second blocked
    /// click still gets feedback while the label is already showing.
    ///
    /// `shakeOnAppear` is for labels *inserted by* the denial itself (their `onChange` never sees
    /// the first bump). Leave it off for persistent labels that merely mount on mode switches —
    /// otherwise they replay an old shake every time they appear.
    func denyShake(trigger: Int, shakeOnAppear: Bool = false) -> some View {
        modifier(DenyShakeModifier(trigger: trigger, shakeOnAppear: shakeOnAppear))
    }
}

private struct ReduceAnimationsModifier: ViewModifier {
    @AppStorage(ReduceAnimationsSetting.key) private var appPreference = ReduceAnimationsSetting.fallback
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var shouldReduceAnimations: Bool {
        ReduceAnimationsSetting.resolve(
            appPreference: appPreference,
            systemReduceMotion: systemReduceMotion
        )
    }

    func body(content: Content) -> some View {
        content.animationReduction(shouldReduceAnimations)
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

/// Keeps an in-flight status visible without mounting an indeterminate spinner clock when motion is
/// reduced. The static symbol deliberately matches the existing iCloud sync affordance.
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

/// Horizontal sine shake driven by an animatable phase (0→1 plays `shakes` full oscillations).
private struct DenyShakeEffect: GeometryEffect {
    var phase: CGFloat
    var travel: CGFloat = 5
    var shakes: CGFloat = 3

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: travel * sin(phase * .pi * shakes * 2),
            y: 0
        ))
    }
}

private struct DenyShakeModifier: ViewModifier {
    let trigger: Int
    let shakeOnAppear: Bool
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .modifier(DenyShakeEffect(phase: phase))
            .onChange(of: trigger) { shake() }
            .onAppear {
                if shakeOnAppear, trigger > 0 { shake() }
            }
    }

    private func shake() {
        // Restart from zero so back-to-back triggers each play a full shake.
        phase = 0
        withAnimation(.linear(duration: 0.4)) {
            phase = 1
        }
    }
}
