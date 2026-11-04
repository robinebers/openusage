# Updates

OpenUsage updates itself with [Sparkle](https://sparkle-project.org). It verifies every update before
installing it.

- **Automatic checks.** About once an hour. A found update shows an **Update Available** banner at the
  top of the panel. Click **Install Update** to open the update window, which lists what's new in that version. Closing the banner snoozes it
  until the next check finds the update.
- **Manual check.** **Check for Updates…** in the dashboard's **⋯** menu or in **Settings → Updates**.
- **Turn it off.** **Settings → Updates → Check Automatically** stops the background checks. Manual
  checks still work.
- OpenUsage shows a Dock icon while the update window is open, then hides it again.

## Beta updates

**Settings → Updates → Beta Updates** adds pre-release builds on top of stable releases. Turn it off to
go back to stable only. You stay on your current version until the next stable release catches up.

## Where updates come from

- Builds come from OpenUsage's GitHub releases. The appcast is
  `https://robinebers.github.io/openusage/appcast.xml`.
- Each download is notarized by Apple and signed by OpenUsage. The app refuses anything that doesn't match.
- Only the official release build updates. Local developer builds don't.
