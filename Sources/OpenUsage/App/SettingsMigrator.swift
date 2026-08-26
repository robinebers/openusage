import Foundation

/// One ordered step that brings persisted settings from schema version `version - 1` up to `version`.
/// A step is a pure transform over a `UserDefaults` domain — rename a key, seed a new default, drop a
/// dead one. Keep it idempotent: an interrupted upgrade may re-run the same step on the next launch.
struct SettingsMigration: Sendable {
    /// The schema version this step produces. Versions are whole numbers counting up (1, 2, 3, …) and
    /// are independent of the app's marketing version — they change only when a *setting's shape* does.
    let version: Int
    /// Applies the change to `defaults`. Throw to abort the cascade: the engine stops, keeps the version
    /// at the last success, and retries from there on the next launch.
    let migrate: @Sendable (UserDefaults) throws -> Void
}

/// The settings schema: its current version and the ordered migrations that build up to it. This enum is
/// the ONLY thing to edit when a setting changes shape — append a `SettingsMigration` and bump `current`
/// to match. The engine (`SettingsMigrator`) never needs to change.
enum SettingsSchema {
    /// Current schema version. Keep equal to the highest migration `version` below (or the baseline when
    /// there are none). This is NOT the app version — bump it only alongside a migration you add.
    static let current = 2

    /// The provider IDs that existed when the v2 migration shipped, frozen forever. A migration is a
    /// point-in-time transform: any future build with more providers also contains this migration, so a
    /// legacy install jumping several versions is first converted with this exact list, and
    /// `NewProviderSeeder` then picks up everything added afterwards as new. Never edit this list.
    static let v2ProviderIDs = [
        "antigravity", "claude", "codex", "copilot", "cursor", "devin", "grok", "openrouter", "zai"
    ]

    /// Ordered migrations, each taking the domain one version higher. v1 is the baseline — the settings
    /// shape at the moment this system replaced the beta-era "wipe on every update" behavior — so it
    /// needs no transform. Migrations reference storage keys as string literals on purpose: they are
    /// frozen transforms and must keep working even if a store renames its key constant later.
    static let migrations: [SettingsMigration] = [
        // v2 unifies every install onto enabled-list mode (see `ProviderEnablementStore`) and records
        // which providers the install has seen (`NewProviderSeeder` probes only never-seen ones):
        // - legacy disabled-list installs convert to the equivalent enabled list (behavior-preserving:
        //   the effective on/off set is identical before and after),
        // - every install gets the known-provider set seeded with the providers of this era, so nothing
        //   already shipped is retroactively treated as "new" and re-enabled against the user's choice.
        SettingsMigration(version: 2) { defaults in
            if defaults.stringArray(forKey: "openusage.enabledProviders.v1") == nil {
                let disabled = Set(defaults.stringArray(forKey: "openusage.disabledProviders.v1") ?? [])
                let enabled = v2ProviderIDs.filter { !disabled.contains($0) }
                defaults.set(enabled, forKey: "openusage.enabledProviders.v1")
                defaults.removeObject(forKey: "openusage.disabledProviders.v1")
            }
            if defaults.stringArray(forKey: "openusage.knownProviders.v1") == nil {
                defaults.set(v2ProviderIDs, forKey: "openusage.knownProviders.v1")
            }
        }
    ]
}

/// Versioned, cascading settings migration — the replacement for the beta-era domain wipe. Runs once at
/// launch, BEFORE any store reads `UserDefaults`, so migrated values are already in place when stores
/// load and a true fresh install can still be told apart from an upgrade (its domain is empty).
///
/// The stored schema version (`schemaVersionKey`, an integer) drives everything:
///   - **Existing install:** run every migration whose `version` is above the stored one, in ascending
///     order, persisting the new version after EACH step — so an interrupted or failed upgrade resumes
///     where it left off next launch instead of replaying completed steps.
///   - **Fresh install:** stamp `current` and run nothing; the stores seed their own current-shape
///     defaults right after.
///   - **Legacy install (predates this key):** treated as version 0 and migrated forward from there.
///
/// Crucially there is NO wipe: an app-version change never discards settings. (The old reset silently
/// cleared `betaUpdatesEnabled`, dropping users off the Early Access channel — see `UpdaterController`.)
enum SettingsMigrator {
    /// Where the applied schema version is recorded, in the same standard domain as the settings it
    /// guards. Integer; absent means "never migrated" — a fresh or legacy install, disambiguated at runtime.
    static let schemaVersionKey = "openusage.settings.schemaVersion"

    /// Bring the domain up to `current`. Returns the resulting schema version (for logging and tests).
    @discardableResult
    static func migrate(
        defaults: UserDefaults = .standard,
        domainName: String = Bundle.main.bundleIdentifier ?? "",
        current: Int = SettingsSchema.current,
        migrations: [SettingsMigration] = SettingsSchema.migrations
    ) -> Int {
        var version: Int
        if let stored = defaults.object(forKey: schemaVersionKey) as? Int {
            version = stored
        } else if isFreshInstall(defaults: defaults, domainName: domainName) {
            defaults.set(current, forKey: schemaVersionKey)
            AppLog.info(.config, "fresh install — settings schema stamped at v\(current)")
            return current
        } else {
            version = 0
            AppLog.info(.config, "legacy settings (no schema version) — migrating forward from v0")
        }

        // Already current, or a downgrade (ran a newer build before): leave the recorded version as-is
        // and never re-apply old migrations backward.
        guard version < current else { return version }

        for step in migrations.sorted(by: { $0.version < $1.version })
        where step.version > version && step.version <= current {
            do {
                try step.migrate(defaults)
            } catch {
                AppLog.warn(.config, "settings migration to v\(step.version) failed: \(error.localizedDescription) — will retry next launch")
                return version  // keep the last success; resume here next launch
            }
            version = step.version
            defaults.set(version, forKey: schemaVersionKey)  // persist after EACH step (resumable cascade)
            AppLog.info(.config, "migrated settings to schema v\(version)")
        }

        // Record reaching `current` even when the highest migration is below it (a version bump that
        // needed no data change), so the cascade isn't re-evaluated on every launch.
        if version < current {
            version = current
            defaults.set(current, forKey: schemaVersionKey)
        }
        return version
    }

    /// A genuine first launch has nothing persisted yet. The migrator runs before any store writes
    /// defaults, so an empty domain means fresh; existing keys with no schema version mean a legacy
    /// install to migrate forward. An empty `domainName` (unbundled `swift run`) has no domain to
    /// inspect — treat it as fresh, since there is nothing to migrate.
    ///
    /// Internal (not just the migrator's own check) because `AppDelegate` reads it BEFORE calling
    /// `migrate()` — stamping the schema version makes the domain non-empty, so the answer must be
    /// captured first. `FirstRunSeeder` keys off it to seed a fresh install's enabled providers.
    static func isFreshInstall(
        defaults: UserDefaults = .standard,
        domainName: String = Bundle.main.bundleIdentifier ?? ""
    ) -> Bool {
        guard !domainName.isEmpty else { return true }
        return (defaults.persistentDomain(forName: domainName) ?? [:]).isEmpty
    }
}
