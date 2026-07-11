# Updates

OpenUsage keeps itself up to date using [Sparkle](https://sparkle-project.org), the standard update
framework for Mac apps. Updates are downloaded from OpenUsage's own release feed and verified before
they install, so you always get a genuine, unmodified build.

## How it works

- **Automatic checks.** The app quietly checks for a new version in the background (about once an hour).
  When one is found, an **Update Available** banner appears at the top of the popover instead of a
  window popping up behind your other apps. Click **Install Update** to open the update window (release
  notes, download, install) front and center. The banner's close button snoozes it; it comes back the
  next time the app finds the update. Because OpenUsage lives in the menu bar, it briefly shows a Dock
  icon while the update window is open, then hides again.
- **Manual check.** Open **Settings → Updates** and click **Check for Updates…** at any time.
- **Turn it off.** The **Update Automatically** switch in **Settings → Updates** stops the
  background checks. You can still check manually.

## Beta updates

**Settings → Updates → Beta Updates** opts you into pre-release builds before they ship to
everyone. Turn it off to go back to stable-only; you'll stay on your current version until the next
stable release catches up.

Everyone always receives stable releases — the beta option only *adds* pre-release builds on top.

## Where updates come from

Update builds are published on OpenUsage's GitHub releases, and the list of available versions (the
"appcast") is served from `https://robinebers.github.io/openusage/appcast.xml`. Each download is
signed two ways — Apple notarization plus OpenUsage's own signature — and the app refuses anything that
doesn't match. This is only available in the official signed release build, not in local developer
builds.
