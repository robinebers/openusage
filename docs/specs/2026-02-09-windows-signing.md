2026-02-09

# Windows code signing (prep)

## Goal
- Prepare CI to import a Windows signing certificate when secrets exist.

## Non-goals
- Do not enable signing without owner-provided secrets.
- Do not add placeholder thumbprints to `tauri.conf.json`.

## Plan
- Add a Windows-only CI step that imports a PFX from secrets into the user cert store.
- Document required secrets and `tauri.conf.json` fields for the owner.

## Definition of done
- Publish workflow has a conditional Windows cert import step.
- `OWNER_FOLLOW.md` lists secrets + config the owner must set.
