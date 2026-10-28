import Foundation

extension UserDefaults {
    func enumValue<T: RawRepresentable>(forKey key: String, default fallback: T) -> T where T.RawValue == String {
        string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }

    func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) as? Bool ?? fallback
    }
}
