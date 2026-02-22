# App State Architecture (PR #209)

## Source of truth stores
- `app-ui-store`: UI view state (`activeView`, `showAbout`)
- `app-plugin-store`: plugin metadata + persisted plugin settings
- `app-preferences-store`: persisted user preferences (display/theme/tray/system)

## Derived values
- `app-derived-store` is intentionally derived-only.
- `displayPlugins` + `navPlugins` are computed by `useAppPluginViews`.
- `settingsPlugins` is computed by `useSettingsPluginList`.
- `autoUpdateNextAt` is runtime scheduling state from `useProbe`.

## Main data flow
1. `App.tsx` composes hooks and owns cross-domain orchestration.
2. Source stores are updated from bootstrap/settings/probe actions.
3. Derived hooks recompute view models from source state.
4. `App.tsx` mirrors derived results into `app-derived-store`.
5. `AppShell` and `AppContent` consume store state and render UI.

## Guardrails
- Do not persist user-input/source state into `app-derived-store`.
- Keep `app-derived-store` writes explicit (`setPluginViews({ displayPlugins, navPlugins })`).
- Keep derivations pure and colocated with domain hooks.
