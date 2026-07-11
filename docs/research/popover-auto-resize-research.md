# Smooth Content-Driven Auto-Resize for the Custom Menu-Bar Panel

> **Historical / superseded.** This 2026-06-25 research preceded the coordinated content-driven panel
> resize that shipped later that day and was subsequently refined. See the current
> [AppKit bridge](../architecture.md#the-appkit-bridge),
> [`DashboardView.swift`](../../Sources/OpenUsage/Views/DashboardView.swift),
> [`PanelHeightCoordinator.swift`](../../Sources/OpenUsage/Views/PanelHeightCoordinator.swift), and
> [`PanelHeightController.swift`](../../Sources/OpenUsage/App/PanelHeightController.swift). The rejected
> approaches and proposed file map below are preserved as historical research, not current setup
> instructions.

**Research report — 2026-06-25**
**Question:** How do real macOS apps auto-resize a *custom, keyboard-capable* popover to its content smoothly — without (a) resize lag/stutter and (b) the "diagonal" jank when a screen-slide and a window-resize run at the same time — given OpenUsage must keep its custom `NSPanel` for keyboard shortcuts?

---

## Executive Summary

Both failures you hit have **one root cause: two animation clocks fighting.** Your content/slide is animated by SwiftUI's engine; your window frame was animated by AppKit (`KVO(preferredContentSize) → animated setFrame`). Two independent timelines with different curves, started at slightly different moments, produce stutter (clock A and clock B disagree frame-to-frame) and the "diagonal" (a horizontal SwiftUI curve composited against a vertical AppKit curve).

The fix is not a better AppKit resize animation — it is to **make the window a passive follower of a single SwiftUI-owned height value.** You already have the hard part working: your drag-resize is butter-smooth because it pushes `setFrame(display:false)` synchronously, frame-by-frame, fed by a stream of heights from SwiftUI's `DragGesture`. The recommendation is to **generalize that exact path** so the stream of heights comes from SwiftUI's *animation engine* (an interpolated value) instead of the finger. There is then only one clock, so nothing can fight.

This is genuinely hard and there is **no off-the-shelf API for it** — confirmed by surveying real apps: the polished SwiftUI menu-bar app **FontSwitch** uses the identical `canBecomeKey` panel you do and gives up, shipping a *fixed* size [16]; the competing **Claude-Usage-Tracker** gets smooth auto-resize only by using `NSPopover` (whose `animates` property resizes natively [13]) and pays for it with the exact "not legal to call `-layoutSubtreeIfNeeded` on a view which is already being laid out" recursion warning [9]. `NSPopover` stays off the table for you for the documented reason (its window isn't reliably key in an `LSUIElement` app on macOS 26+, breaking Esc/Return/⌘R and the recorder). So you must build the smooth-resize primitive yourself on the panel — and you've already built it for drag.

**Recommendation:** keep the `MenuBarPanel`; delete the manual drag-resize model users disliked; reinstate auto-fit as a *single-clock follower* — measure the content's ideal height with `onGeometryChange`, push it to the panel through your existing synchronous bridge, and drive screen-switch height changes inside the **same** `withAnimation` that drives the slide (a coordinated "morph"), with sequenced resize via `withAnimation(completionCriteria:completion:)` as the conservative fallback. Both are macOS 15+ APIs, within your floor.

---

## 1. Why this specific combination is hard (the landscape)

There are three viable shapes for a SwiftUI menu-bar surface, and each app picks two of the three properties — *keyboard-key window*, *smooth native content-resize*, *no custom resize code*:

- **`NSPopover`** gives smooth native content-resize for free: "Changes to the content size of the popover will cause the popover to animate while it is shown if the `animates` property is YES" [13][12]. But its window is only key while the whole app is active, and activating an `LSUIElement` app is asynchronous (or denied on macOS 26+), so keystrokes land on the status-item button instead — the documented reason OpenUsage abandoned it. Even apps that accept that tradeoff fight friction: Claude-Usage-Tracker's NSPopover+SwiftUI integration throws layout-recursion warnings caused by creating `NSHostingController` during a layout pass, `withAnimation` mutations mid-layout, `GeometryReader`+`.animation` conflicts, and a fixed `contentSize` conflicting with dynamic SwiftUI content [9].

- **Custom `NSPanel` (`canBecomeKey = true`, `.nonactivatingPanel`)** gives a real key window without activating the app — the keyboard works on the first try. This is your panel, and it's the same one FontSwitch uses ("We become key when using the search bar to receive keyboard input" — `FocusablePanel: NSPanel { override var canBecomeKey: Bool { true } }`, then `panel.makeKey()`) [16]. The cost: you lose `NSPopover.animates`. FontSwitch's answer is a **fixed** panel (`panel.setFrame(frame, display: true)` with a stored `panelSize`) [16] — exactly where OpenUsage landed in PR #717.

- **SwiftUI `Window` / `MenuBarExtra(.window)` scene** can auto-resize to content for free (bind content size to state, wrap in `withAnimation`, SwiftUI's layout engine resizes the window) [6]. But the `.window` style has the same non-key limitation as `NSPopover`, so it's out for the same reason.

**Conclusion:** "custom key-window panel" **and** "smooth content auto-resize" is the one pairing nobody gets for free. You must reimplement the resize. The good news is you already have the smooth primitive (your drag), so this is a generalization, not a from-scratch build.

---

## 2. Root-cause mapping of every prior attempt

Your memory and code record five things that were tried and failed. Each maps cleanly to the two-clocks diagnosis:

1. **`KVO(preferredContentSize) → setFrame`, "stuttered on every screen switch."** `NSHostingController.preferredContentSize` updates at AppKit's cadence (it's a constraint-derived size [2][5]), not on SwiftUI's per-frame animation clock. You then animated the window with a *separate* AppKit animation. Two clocks → stutter. Worse, the measurement and the relayout were happening inside the layout pass — the same recursion trap Claude-Usage-Tracker documented [9].

2. **`animator().setFrame` / `NSAnimationContext` animated resize, "janky."** AppKit's implicit layer-bounds animation stretches the layer's *cached* contents during the animation unless `layerContentsRedrawPolicy` is set correctly, and non-layer-friendly setups are driven by repeated `-setFrame:` on the **main thread**, where "animation performance degrades extremely quickly" [1]. Even done perfectly, it's still a *second* clock fighting the SwiftUI slide.

3. **`setFrame(display:false)`, "instant, no glide."** Correct — a bare `setFrame` has no animation driver. The glide has to come from *something* interpolating the height. You had the right primitive but no interpolated source feeding it. This is the key realization: the primitive isn't broken, it was just being fed a step function instead of a curve.

4. **The "diagonal" on settings open.** The slide is a SwiftUI `.offset` on a spring; the resize was an AppKit `setFrame`. Horizontal-SwiftUI-curve × vertical-AppKit-curve, started a beat apart = a diagonal that arrives crooked. Pure two-clock interference.

5. **Drag-resize: smooth.** The one success. Why? `DragGesture.onChanged` is an *event* callback (not inside a layout pass), and it pushes `setFrame(display:false)` + `layoutSubtreeIfNeeded()` + `displayIfNeeded()` synchronously, one height per tick. The finger is the clock; the window follows exactly. **This is the template for the whole solution.**

---

## 3. The recommended architecture: a single-clock follower

Make the panel height a *pure function of a SwiftUI-owned value*, and let SwiftUI's animation engine be the only thing that ever animates. The window never animates itself; it is repainted at the exact size SwiftUI computed for the current frame.

### 3.1 The primitive (generalize your drag)

Your drag already proves the smooth path:

```swift
// StatusItemController.updateGripResize(by:) — the proven-smooth path
panel.setFrame(rect, display: false)
panel.contentView?.layoutSubtreeIfNeeded()
panel.displayIfNeeded()
```

Keep this bridge. Change only *who feeds it heights*: instead of `MenuBarPopover.resizeBy(translation)` from a finger, feed it `applyHeight(_:)` from a SwiftUI-interpolated value.

### 3.2 Measuring the content's ideal height

Measure the **content's natural height**, independent of the window's current height, so there is no feedback loop. The modern, layout-safe API is `onGeometryChange` (macOS 15+, within your floor) [10][17]; it monitors geometry without expanding layout the way a bare `GeometryReader` does:

```swift
// Measure the SCROLL CONTENT (inner VStack), not the viewport, so the value
// is the ideal height and does not depend on the window height → no feedback loop.
scrollContent
    .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.height }
        action: { ideal in layout.idealHeight[screen] = ideal }
```

Because width is fixed at 320 and the cards size to their content, offering the content *more* vertical room never changes this measured value — the loop is broken by construction. (Pre-macOS-15 fallback if ever needed: `.background(GeometryReader { Color.clear.preference(...) })` [17].)

### 3.3 Clamp + scroll fallback (NSPopover's contentSize-as-max, rebuilt)

```
target = clamp(idealHeight, minHeight, maxPanelHeight())   // you already have maxPanelHeight()
```

When `ideal ≤ maxScreen`, the window fits the content exactly and the `ScrollView` is inert. When `ideal > maxScreen`, the window caps at `maxPanelHeight()` and the scroll engages — which is precisely how `NSPopover.contentSize` behaves ("if your SwiftUI view requests more space than contentSize allows, the bottom is clipped" [12]), only here it scrolls instead of clipping. Keep `maxPanelHeight()` and top-anchoring exactly as today (origin.y = `anchorTopLeft.y - height`, so the panel grows downward from the status item).

### 3.4 Feeding the follower from SwiftUI's animation clock

This is the crux. To get *interpolated* heights (a curve, not a step) without a second clock, mirror the target height into a zero-cost view whose frame SwiftUI animates, and read the in-flight value:

```swift
// A 0×target probe. When `target` changes inside withAnimation, SwiftUI
// interpolates this frame height every render tick and fires the action
// with the interpolated value — the same clock that drives the slide.
Color.clear
    .frame(height: animatedTarget)
    .onGeometryChange(for: CGFloat.self) { $0.size.height }
        action: { h in MenuBarPopover.applyHeight?(h) }   // → the synchronous bridge
```

`applyHeight` pushes to the panel. Because the heights come from SwiftUI's interpolation of `animatedTarget`, the window tracks SwiftUI's curve and clock exactly — identical to how the drag tracks the finger. There is no `NSAnimationContext`, no `animator()`, no AppKit timing to mismatch.

> Equivalent mechanism: a custom `Animatable` modifier whose `animatableData` is the height and whose setter calls `applyHeight` — the classic "drive an NSWindow from a SwiftUI animation" trick. Pick whichever reads cleaner; both put SwiftUI in sole control of the clock.

---

## 4. Solving the "diagonal" — two clean options, both now possible

With the window a passive follower, the slide and the resize are no longer two clocks — the question becomes purely *design*: should they move together or in sequence?

**Option A — Coordinated morph (recommended).** Set the height target to the destination screen's ideal height **inside the same `withAnimation` that drives `slideProgress`.** Both pages are already mounted in the slide `HStack`, so both ideal heights are known. The horizontal offset and the window height then animate on one spring; the panel *morphs* (grows/shrinks) as the new screen slides in — one coherent motion. The old "diagonal" was only ugly because the two axes were on different clocks; on one clock it reads as intentional (this is how system surfaces morph). No extra latency.

```swift
withAnimation(Motion.spring) {
    slideProgress = 1
    animatedTarget = idealHeight[destinationScreen] ?? animatedTarget
}
```

**Option B — Sequenced (conservative fallback).** Slide at constant height, then resize — using the native completion API (macOS 14+, within your floor) [14][7][15]:

```swift
withAnimation(.spring, completionCriteria: .removed) {
    slideProgress = 1
} completion: {
    withAnimation { animatedTarget = idealHeight[destinationScreen] ?? animatedTarget }
}
```

To avoid clipping mid-slide, grow *before* the slide when the destination is taller, and shrink *after* when it's shorter. This is more deliberate and slightly slower; choose it if the morph feels too busy with the glass cards.

**In-screen content changes** (a provider loads in, a row expands, spend rows toggle) are the pure case: no slide, just `withAnimation { animatedTarget = newIdeal }`. The follower handles it identically — that's the auto-resize users are actually asking to get back.

---

## 5. Code sketch mapped to your files

| File | Change |
|---|---|
| `Support/PopoverDismissReader.swift` | Add `static var applyHeight: ((CGFloat) -> Void)?` to the `MenuBarPopover` bridge (same pattern as `beginResize`/`resizeBy`/`dismissHandler`). |
| `App/StatusItemController.swift` | Implement `applyHeight` to clamp to `maxPanelHeight()` and call the **existing** synchronous `setFrame(display:false)` path (without forcing `layoutSubtreeIfNeeded` from the callback — see §6). Drop `PanelHeightStore`/drag plumbing once auto-fit ships. |
| `Views/DashboardView.swift` | Add the `Color.clear.frame(height:).onGeometryChange` probe (or `Animatable` modifier). Measure each screen's ideal height on its scroll content. Set the height target inside the existing slide `withAnimation` (Option A) or sequence it (Option B). Remove `resizeDragger` and the `resizingPanel`/`.frame(maxHeight:.infinity)` fill once auto-fit is proven. |
| `Stores/LayoutStore.swift` | Hold `idealHeight: [PopoverScreen: CGFloat]` (or two simple `@State`s in `DashboardView`). |

The ~120 lines of dead auto-size machinery already flagged for cleanup (`animatedPopoverHeight`, `ScreenHeightReader`, `contentHeight` bindings) should be deleted, not revived — the new path is smaller and clock-unified.

---

## 6. The one pitfall that will bite you: layout reentrancy

The competitor's recursion warning — *"It's not legal to call `-layoutSubtreeIfNeeded` on a view which is already being laid out"* — was caused by doing layout work *during* a layout pass [9]. `onGeometryChange`'s action (and an `Animatable` setter) can fire *inside* SwiftUI's layout. Your drag is safe because `DragGesture.onChanged` is an event callback, not a layout-time callback — so synchronous `layoutSubtreeIfNeeded()` there is fine. To stay safe when the feed is animation-driven:

- In `applyHeight`, call `panel.setFrame(rect, display: false)` and **do not** force `panel.contentView?.layoutSubtreeIfNeeded()` from inside the callback. With top-anchored content at fixed width, growing the window only *reveals* already-laid-out content — there's nothing to relayout, so the synchronous layout call (the part that risks reentrancy) is unnecessary here. Let `displayIfNeeded()` / the normal CA draw cycle paint it.
- Set the window bounds *explicitly per frame* (no implicit `animator()` animation), so Core Animation never stretches a stale cached layer [1] — each frame the layer is already the right size with the right content.
- Never create the `NSHostingController` lazily during a resize/layout (you create it once at startup — keep it that way) [9].
- Guard `applyHeight` with a re-entrancy flag (`isApplyingHeight`) so a frame change can't recursively trigger another.

---

## 7. Alternatives considered and rejected

- **Go back to `NSPopover` for free smooth resize.** Rejected: its window isn't reliably key in your `LSUIElement` app on macOS 26+ (your documented root cause), which breaks the keyboard — the whole reason `MenuBarPanel` exists. NSPopover+SwiftUI also brings its own layout-recursion friction [9]. No-compromise on keyboard means no NSPopover.

- **AppKit Core-Animation resize (`NSAnimationContext` + `animator().setFrame`, `layerContentsRedrawPolicy = .onSetNeedsDisplay`).** This *can* be made smooth in isolation [1], but it is a second clock — it cannot be curve-matched to SwiftUI's spring, so it reintroduces the diagonal. Only viable if you also drove the slide from AppKit, which you don't want. Rejected in favor of the single SwiftUI clock.

- **Keep the manual drag handle.** Rejected: it's the thing users disliked, and it's redundant once auto-fit returns. (A future "pin a max height" power-user option could reuse the bridge, but it's not needed for the core ask.)

- **`MenuBarExtra(.window)` / SwiftUI `Window` scene** for free auto-resize [6]. Rejected: same non-key keyboard limitation as NSPopover.

---

## 8. Verification plan

The popover can't be auto-opened/screenshotted from here, so this needs your eyes, but make it objective:

1. **In-screen resize** (toggle a provider's spend rows on Dashboard): the panel should grow/shrink in one smooth motion, top edge pinned, no card stretch or one-frame clip.
2. **Screen switch** (Dashboard → Settings, the tall one): with Option A, slide + grow should read as a single morph; with Option B, a clean two-beat. No diagonal, no wobble.
3. **Screen-cap case** (very tall content / short display): window caps at `maxPanelHeight()` and the inner `ScrollView` engages with no layout fight.
4. **Reentrancy:** run from Xcode/Console and confirm **zero** "not legal to call `-layoutSubtreeIfNeeded`…" warnings during rapid screen-switch spamming [9].
5. **Glass:** confirm no white-flash on the `.quaternary` cards during resize — resize is a pure bounds change (no opacity), so the offset-not-transition rule you already rely on still holds.
6. Add a regression test where it fits (per AGENTS.md): assert `applyHeight` clamps to `[minHeight, maxPanelHeight()]` and that the height target equals the measured ideal below the cap.

---

## 9. Limitations & caveats

This report is grounded in your actual code (mapped by source exploration) plus authoritative AppKit/SwiftUI documentation, primary-source developer blogs, and two directly-analogous open-source apps. The central claim — that a SwiftUI-interpolated value feeding your synchronous `setFrame` bridge will be as smooth as your drag — is a strong inference from (a) your drag already being smooth via that exact bridge and (b) the single-clock principle, **not** a measured result; it must be verified on-device (§8). The reentrancy mitigation (§6) is the highest-risk detail: if dropping the synchronous `layoutSubtreeIfNeeded` from the callback causes a perceptible one-frame content lag during fast animations, the fallback is to keep it but guard against reentrancy with a flag and/or hop the push out of the layout pass — at the cost of slightly more complexity. `onGeometryChange`'s exact firing cadence during animations isn't formally documented [10][17]; if it proves too coarse, the `Animatable`-modifier mechanism gives frame-locked updates. None of these change the architecture — only which knob you turn.

---

## Bibliography

[1] Jonathan Willing. "A short guide to OS X animations." https://jwilling.com/blog/osx-animations/ — `layerContentsRedrawPolicy` (`NSViewLayerContentsRedrawDuringViewResize` vs `OnSetNeedsDisplay`); main-thread `-setFrame:` degradation; CA-on-background-thread.

[2] Apple. "setFrame(_:display:animate:) — NSWindow." https://developer.apple.com/documentation/appkit/nswindow/1419519-setframe

[3] Jonathan Willing. "JNWAnimatableWindow." https://github.com/jwilling/JNWAnimatableWindow — layer-backed NSWindow animation.

[4] Apple. "sizingOptions — NSHostingController." https://developer.apple.com/documentation/swiftui/nshostingcontroller/sizingoptions

[5] Apple. "preferredContentSize — NSHostingController." https://developer.apple.com/documentation/swiftui/nshostingcontroller/preferredcontentsize

[6] Itsuki. "SwiftUI/MacOS: Auto Window/Panel Resizing Based on Some State." https://medium.com/@itsuki.enjoy/swiftui-macos-auto-window-panel-resizing-based-on-some-state-a8f8ffc4182f

[7] Antoine van der Lee. "withAnimation completion callback with animatable modifiers." https://www.avanderlee.com/swiftui/withanimation-completion-callback/

[8] Michael Tsai (quoting Brian Webster). "How NSHostingView Determines Its Sizing." https://mjtsai.com/blog/2023/08/03/how-nshostingview-determines-its-sizing/

[9] hamed-elfayome / Claude-Usage-Tracker, Discussion #64. "Fix: Layout recursion warning in NSPopover/SwiftUI integration." https://github.com/hamed-elfayome/Claude-Usage-Tracker/discussions/64 — `-layoutSubtreeIfNeeded` reentrancy; NSHostingController-during-layout; `withAnimation` mid-pass; GeometryReader+`.animation`; fixed `contentSize` vs dynamic content.

[10] Fatbobman. "4 Ways to Get View Size in SwiftUI: From GeometryReader to onGeometryChange." https://fatbobman.com/en/snippet/how-to-obtain-view-dimensions-in-swiftui/

[11] Apple. "NSPopover." https://developer.apple.com/documentation/appkit/nspopover

[12] Apple. "contentSize — NSPopover." https://developer.apple.com/documentation/appkit/nspopover/1524677-contentsize

[13] Apple. "animates — NSPopover." https://developer.apple.com/documentation/appkit/nspopover/1526527-animates — content-size changes animate while shown when `animates` is YES.

[14] Apple. "withAnimation(_:completionCriteria:_:completion:)." https://developer.apple.com/documentation/swiftui/withanimation(_:completioncriteria:_:completion:)

[15] Paul Hudson. "How to run a completion callback when an animation finishes." https://www.hackingwithswift.com/quick-start/swiftui/how-to-run-a-completion-callback-when-an-animation-finishes

[16] JPToroDev / FontSwitch. https://github.com/JPToroDev/FontSwitch — `FocusablePanel: NSPanel` with `canBecomeKey = true`, `panel.makeKey()`, fixed `panel.setFrame(frame, display: true)`; an analogous SwiftUI+AppKit key-window menu-bar app that ships a fixed panel size.

[17] Apple. "View.onGeometryChange(for:of:action:)." https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:)

[18] Cindori. "Make a floating panel in SwiftUI for macOS." https://cindori.com/developer/floating-panel — `FloatingPanel<Content>: NSPanel`, `.nonactivatingPanel`, `canBecomeKey` override; fixed `contentRect` sizing.

[19] Fazm. "SwiftUI Menu Bar App With a Floating Window: Best Practices." https://fazm.ai/blog/swiftui-menu-bar-app-floating-window-best-practices — NSHostingView relayout-per-frame during live resize; `makeKey()` for text fields; status-item positioning.

[20] Apple Developer Forums, thread 665638. "Animating popover size changes." https://developer.apple.com/forums/thread/665638 — confirmed symptom: popover frame changes instantly while inner controls animate awkwardly; SwiftUI `.popover` does not animate the frame even under `withAnimation`.

[21] dboydor / PopoverResize. https://github.com/dboydor/PopoverResize — resizable NSPopover wrapper (min/max + resize callback).

[22] codestudy.net. "SwiftUI: How to Animate View Frame Resize (Transition Between Known Dimensions)." https://www.codestudy.net/blog/swiftui-animate-resize-of-a-view-frame/
