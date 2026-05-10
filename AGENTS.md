# UsageMeter

## Instructions
- Use simple, concise language.
- Be precise. No fluff.
- Do not over-engineer. This app is used by 2-5 people internally.

## Guardrails
- Use trash for deletes.
- Use `mv` / `cp` to move and copy files.
- Bugs: add regression test when it fits.
- Keep files under about 400 LOC; split/refactor as needed.
- Simplicity first: handle important cases only.
- New functionality: small or clearly necessary.
- Never delete files, folders, or data unless explicitly approved or part of a plan.

## Stack
- C#
- WinUI 3
- Windows App SDK
- .NET 11 preview
- xUnit tests

## Error Handling
- Expected issues: explicit user-facing result.
- Unexpected issues: fail loudly.
- Never add silent fallbacks.

## Before Creating Pull Request
- Run `dotnet build .\UsageMeter.Windows.slnx`.
- Run `dotnet test .\tests\UsageMeter.Tests\UsageMeter.Tests.csproj`.
- Ensure `README.md` lists supported providers.
- If provider output fields change, audit cache/result models and add tests for gaps.
- If visual changes are included, provide before/after screenshots.

## Project Memories
Use this list when asked to remember things. Keep each item concise.
