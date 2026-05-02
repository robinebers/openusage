# Adding Provider Support on Windows

These notes are based on what worked on my Windows laptop while making Codex and Antigravity usable in OpenUsage. They are recommendations, not guarantees. Provider internals, install paths, local server flags, token formats, and CLI output can change without warning.

## Confirmed vs Unconfirmed Providers

Confirmed on this laptop:

- Codex
- Antigravity

Not confirmed on this laptop:

- Claude Code
- Cursor
- Copilot
- Other providers

Reason: this machine only has working Codex and Antigravity accounts for validation. Claude Code and Cursor may be installed, but without a paid/logged-in account I can only verify obvious compatibility paths, not real quota or usage responses.

Recommendation: treat non-confirmed providers as best-effort Windows support. If they fail on another machine, the owner may need to inspect their real install path, auth path, local state database, CLI behavior, or subscription API response and add a small compatibility patch.

## General Windows Lessons

- Do not assume macOS paths or process tooling work on Windows.
- Avoid visible subprocess windows. Any host-side command used for probes should be launched with `CREATE_NO_WINDOW` on Windows.
- Prefer explicit Windows paths where needed:
  - `%USERPROFILE%\.codex`
  - `%USERPROFILE%\.config\codex`
  - `%APPDATA%\Antigravity\User\globalStorage\state.vscdb`
  - `%LOCALAPPDATA%\Programs\Antigravity`
- Convert WSL-style paths like `/mnt/c/Users/...` before using them from native Windows code.
- Redact Windows paths and tokens in logs. Provider auth files often contain enough data to compromise accounts.
- Test with the same runtime path the app uses. Shell commands can pass while Tauri/Rust-launched commands fail.

## Subprocess Popups

The rapid popup issue came from provider probes spawning helper commands visibly on Windows.

What worked:

- Route command creation through a shared hidden command helper.
- Apply Windows `CREATE_NO_WINDOW`.
- Use it for:
  - `sqlite3`
  - package runners like `bunx`, `pnpm dlx`, `yarn dlx`, `npm exec`, `npx`
  - PowerShell process discovery
  - CLI auth helpers

Caveat: this only hides console windows for subprocesses created by OpenUsage. If a provider CLI starts its own GUI/window, this may not suppress it.

## Codex

What worked:

- Read Codex auth from file first:
  - `CODEX_HOME/auth.json` when `CODEX_HOME` is set
  - `~/.config/codex/auth.json`
  - `~/.codex/auth.json`
- Preserve the discovered auth home and pass it to token usage tooling.
- Refresh OpenAI OAuth tokens when needed, then save the updated auth payload back to the source file/keychain.
- Query ChatGPT/Codex quota headers for subscription limits:
  - session usage
  - weekly usage
  - credits
- Query `@ccusage/codex` for token/cost lines:
  - Today
  - Yesterday
  - Last 30 Days
- On Windows, enrich `PATH` before running package managers because Node/npm/bun installs are often outside the app's inherited environment.
- On my laptop, the token/cost side was sensitive to WSL vs PowerShell paths. Running the equivalent `ccusage` command from PowerShell could fail to find the expected Codex path, while the WSL environment/path layout was the one that made sense for my setup.
- The implementation should pass the discovered Codex auth directory as `homePath` and convert WSL-style paths like `/mnt/c/Users/...` when native Windows code needs to touch them.
- Try package runners in a fallback order instead of assuming one exists.

Recommendations:

- Keep Codex auth lookup simple and explicit.
- Do not silently ignore bad auth. Show a clear login message like `Run codex to authenticate`.
- Treat `ccusage` as optional. Quota headers can still work if token/cost usage cannot be computed.
- If native Windows package runners cannot find the right Codex files, consider adding an explicit WSL execution path for `ccusage` instead of assuming PowerShell and WSL see the same filesystem shape.
- Keep tests for:
  - `CODEX_HOME`
  - `~/.config/codex` vs `~/.codex` precedence
  - missing package runner
  - malformed `ccusage` output
  - Windows path expansion

Caveats:

- Auth file structure can change.
- ChatGPT/Codex quota headers can change.
- `@ccusage/codex` output can change.
- Native PowerShell and WSL may resolve `~`, `PATH`, Node package binaries, and Codex home differently. What worked for me may need adjustment on machines that do not use WSL.
- API pricing estimates are only as accurate as the model mapping and current pricing data.

## Antigravity

What worked:

- Antigravity stores useful state on Windows at:
  - `%APPDATA%\Antigravity\User\globalStorage\state.vscdb`
- The live Antigravity language server process was:
  - `language_server_windows_x64.exe`
- The process command line included useful flags:
  - `--csrf_token`
  - `--extension_server_port`
  - `--app_data_dir antigravity`
- Windows process discovery needed PowerShell/CIM, not `/bin/ps`.
- Windows listening port discovery needed `Get-NetTCPConnection`, not `lsof`.
- Rust-launched PowerShell did not reliably bind `param(...)` arguments in this setup. Embedding the already-sanitized process name/PID into the script worked better.
- The local Antigravity `GetUserStatus` endpoint accepted `{}`. It rejected the metadata body inherited from similar provider code.
- The successful local status call returned:
  - plan name
  - model config data
  - quota fractions
  - reset times

Recommendations:

- Prefer live language-server data when Antigravity is running.
- Fall back to the SQLite/OAuth/cloud path only when local discovery fails.
- Test the exact app runtime, not only manual curl/PowerShell.
- Keep Antigravity LS discovery configurable by:
  - process name
  - marker flag/value
  - CSRF flag
  - extension port flag
- Probe both HTTP and HTTPS local ports. Some local ports use self-signed HTTPS.
- Treat any HTTP response during port probing as evidence that the port is alive, then validate with the real status call.

Caveats:

- Antigravity is new and may change process names, flags, endpoints, or database keys.
- `GetUserStatus` accepting `{}` worked on this laptop. Other versions may need a different request body.
- SQLite fallback depends on `sqlite3` availability and on Antigravity's state DB schema.
- Local language-server ports change every run.
- Multiple language-server processes can exist; pick the one matching Antigravity markers and then probe actual listening ports.

## Cursor

What was adjusted:

- Cursor's state DB path must be platform-aware.
- macOS path:
  - `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
- Windows path:
  - `%APPDATA%\Cursor\User\globalStorage\state.vscdb`
- The plugin should read Cursor OAuth values from the Windows state DB before trying keychain fallback.

Recommendations:

- Prefer SQLite state DB auth on Windows.
- Do not rely on macOS keychain behavior for Windows.
- If Cursor changes its auth keys or app folder name, inspect `state.vscdb` on the target machine.

Caveats:

- I could not confirm real Cursor paid usage responses on this laptop.
- The path fix removes an obvious Windows blocker, but it does not guarantee Cursor's API response format, subscription state, or token refresh flow will match every account.
- If Cursor stores auth only in Windows Credential Manager on a future version, OpenUsage may need explicit Windows Credential Manager support.

## Claude Code

What already exists:

- Claude config home defaults to:
  - `~/.claude`
- `CLAUDE_CONFIG_DIR` can override the config location.
- Credentials are read from `.credentials.json` when available.
- Token/cost usage uses `ccusage` as optional extra data.

Recommendations:

- Prefer file/env credential lookup on Windows.
- Keep `ccusage` optional. Claude quota/status can still show a login/subscription error without token-cost lines.
- If Claude Code works on a machine but OpenUsage cannot find it, check `CLAUDE_CONFIG_DIR` and the real `.credentials.json` location first.

Caveats:

- I could not confirm real Claude Code paid usage responses on this laptop.
- Current keychain-style fallback is mostly useful for macOS-style credential storage. If Claude Code stores credentials only in Windows Credential Manager, OpenUsage may need explicit Windows Credential Manager support.
- If the user is not subscribed or not logged in, a clear `Token expired` or login error is expected and does not prove the Windows integration is broken.

## Windows UI Caveats

- The macOS floating widget model does not map cleanly to Windows.
- Windows should use a normal decorated window:
  - solid background
  - no transparent glass border
  - close button hides to tray instead of exiting
  - tray right-click menu should include Restart and Quit
- Keep the tray icon as the OpenUsage app icon on Windows. Provider icons can be shown inside the app, but the system tray should identify the app itself.

## Verification Checklist

- Start the provider app/CLI normally.
- Confirm the relevant auth file or state DB exists.
- Confirm OpenUsage can read the path from the app runtime.
- Confirm hidden subprocesses do not flash windows.
- Confirm the live provider probe returns real lines.
- Confirm the UI is not showing stale error state.
- Confirm logs redact paths and tokens.
- Build and run the packaged Windows exe, not only dev mode.

## Final Guidance

Use these notes as a starting point for Windows provider support. Do not assume another machine will match this one. When a provider fails, verify in this order:

1. Real install path.
2. Real auth/state path.
3. Real process name and command-line flags.
4. Real local ports.
5. Real request body accepted by the provider.
6. Real app runtime behavior.

Manual shell success is useful, but it is not enough. The app must pass the same probe through the Rust/Tauri runtime.
