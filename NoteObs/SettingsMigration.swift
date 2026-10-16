import Foundation

/// macOS keys the preferences domain by bundle identifier, so renaming the bundle makes every saved
/// setting look gone: no folder, no theme, no font. This copies the app's own settings over from
/// the domains earlier builds used, and only where the current domain has nothing yet, so a choice
/// the user made after the move is never overwritten.
enum SettingsIdentityMigration {
    /// Bundle identifiers the app has shipped with, oldest last. Add a new entry when renaming.
    static let legacyDomains = ["dev.martystev.totclone", "com.example.TotClone"]

    @discardableResult
    static func migrate(keys: [String], to current: SettingsStore) -> [String] {
        migrate(keys: keys, from: legacyDomains.map { UserDefaultsStore(domain: $0) }, to: current)
    }

    static func migrate(keys: [String], from legacyStores: [SettingsStore], to current: SettingsStore) -> [String] {
        var moved: [String] = []
        for legacy in legacyStores {
            for key in keys where current.object(forKey: key) == nil {
                guard let value = legacy.object(forKey: key) else { continue }
                current.set(value, forKey: key)
                moved.append(key)
            }
        }
        return moved
    }
}
