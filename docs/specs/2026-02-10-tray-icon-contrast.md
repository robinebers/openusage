# Windows Tray Icon Contrast

## Goal
- Keep dynamic tray icons visible on dark Windows taskbars.

## Scope
- Add configurable ink color for dynamic tray icons.
- Use light ink on Windows.

## Non-Goals
- Theme detection or automatic light/dark switching.
- Changes to static tray icon assets.

## Approach
- Add `color` to tray icon rendering API.
- Use `#f8f8f8` on Windows and black elsewhere.

## Testing
- Manual: verify dynamic tray icon remains visible on Windows dark taskbar.

## Risks
- Light ink may be too bright on light taskbars (acceptable until theme detection is added).

## Open Questions
- None.
