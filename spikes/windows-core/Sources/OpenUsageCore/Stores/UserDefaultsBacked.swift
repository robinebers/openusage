import Foundation

extension UserDefaults {
    /// Read a `RawRepresentable` (String-backed) enum from defaults, falling back to `fallback` when
    /// the key is unset or holds an unrecognized raw value. The single home for the
    /// `string(forKey:).flatMap(init(rawValue:)) ?? default` idiom that every persisted enum setting
    /// shares — so a new persisted enum reads its stored choice without restating the parse.
    func enumValue<T: RawRepresentable>(forKey key: String, default fallback: T) -> T where T.RawValue == String {
        string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }

    /// Read a `Bool` with a real default: `bool(forKey:)` returns `false` for an unset key, which can't
    /// express an opt-out (default-on) setting. This reads the stored bool when present and falls back
    /// to `fallback` only when the key is genuinely unset — so a default-on toggle starts on yet still
    /// honors a user's explicit off. The single home for the `object(forKey:) as? Bool ?? default` idiom.
    func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) as? Bool ?? fallback
    }
}

/// A `String`-raw enum persisted under a fixed `UserDefaults.standard` key, with a default for when the
/// key is unset. Conformers get a free `current` accessor, removing the per-enum copy of the
/// read-with-default idiom. Stores that read from an injected (non-standard) `UserDefaults` or an
/// instance-scoped key use `UserDefaults.enumValue(forKey:default:)` directly instead.
protocol UserDefaultsBacked: RawRepresentable where RawValue == String {
    /// The `UserDefaults.standard` key this setting persists under.
    static var key: String { get }
    /// The value used when the key is unset or holds an unrecognized raw value.
    static var fallback: Self { get }
}

extension UserDefaultsBacked {
    /// The stored choice, read live from `UserDefaults.standard` (falls back to `fallback`).
    static var current: Self {
        UserDefaults.standard.enumValue(forKey: key, default: fallback)
    }
}
