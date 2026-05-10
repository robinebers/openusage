# Contributing to UsageMeter

UsageMeter is small, Windows-only, and internal-first. Keep changes direct.

## Ground Rules

- Keep it simple.
- One PR per concern.
- No new dependency without a clear reason.
- Add a regression test when it fits.
- Include before/after screenshots for visual changes.
- Keep files under about 400 lines.

## Build And Test

```powershell
dotnet build .\UsageMeter.Windows.slnx
dotnet test .\tests\UsageMeter.Tests\UsageMeter.Tests.csproj
```

## Providers

Providers are native C# implementations under `src/UsageMeter.Core/Providers`.

Provider additions should include:

- Provider implementation.
- Provider icon in `src/UsageMeter.App/Assets/Providers`.
- Tests for parsing, path handling, or result mapping when practical.
- README update listing the provider.

## Code Standards

- C# and WinUI only.
- Prefer explicit, readable code over abstraction.
- Expected issues should return clear user-facing results.
- Unexpected issues should fail loudly.
