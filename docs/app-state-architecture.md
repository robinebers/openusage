# App State Architecture

## Source of truth stores
- `app-ui-store`: UI view state (`activeView`, `showAbout`)
- `app-plugin-store`: plugin metadata + persisted plugin settings
- `app-preferences-store`: persisted user preferences (display/theme/tray/system)

## Derived values
- `displayPlugins` + `navPlugins` are computed by `useAppPluginViews`.
- `settingsPlugins` is computed by `useSettingsPluginList`.
- `autoUpdateNextAt` is runtime scheduling state from `useProbe`.
- `selectedPlugin` is computed by `useAppPluginViews`.

## Main data flow
1. `App.tsx` composes hooks and owns cross-domain orchestration.
2. Source stores are updated from bootstrap/settings/probe actions.
3. Derived hooks recompute view models from source state.
4. `App.tsx` passes derived values directly to `AppShell` and `AppContent`.
5. `AppShell` and `AppContent` render from those direct props and source stores.

## Guardrails
- Keep source-of-truth state in dedicated stores (`app-ui-store`, `app-plugin-store`, `app-preferences-store`).
- Keep derived values computed in domain hooks and passed directly to composition components.
- Avoid effect-based mirroring of derived values into a separate store.
- Keep derivations pure and colocated with domain hooks.
