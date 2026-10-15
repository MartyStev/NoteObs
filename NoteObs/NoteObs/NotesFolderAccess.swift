import Foundation

/// Keeps a security-scoped folder grant alive for exactly as long as the store that borrowed it.
/// Starting and stopping are paired here so no call site has to remember the balance.
final class SecurityScope: Sendable {
    private let url: URL
    private let granted: Bool

    /// Asks for access when the URL can carry a scope. Plain paths answer "no" and stay untouched.
    init(url: URL, securingAccess: Bool) {
        self.url = url
        self.granted = securingAccess && url.startAccessingSecurityScopedResource()
    }

    var isGranted: Bool { granted }

    deinit {
        if granted {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

/// The slice of settings storage the app reads and writes. UserDefaults in the app, a dictionary in
/// the checks, so a regression run never leaves files behind in the user's preferences.
protocol SettingsStore {
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
}

struct UserDefaultsStore: SettingsStore {
    /// Computed rather than stored: UserDefaults is thread-safe, so there is no shared state to guard.
    static var standard: UserDefaultsStore { UserDefaultsStore(UserDefaults.standard) }

    /// Another preferences domain, used to read what an earlier build saved under a different name.
    init(domain: String) {
        defaults = UserDefaults(suiteName: domain) ?? .standard
    }

    private let defaults: UserDefaults

    init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }

    func object(forKey key: String) -> Any? {
        defaults.object(forKey: key)
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ value: Any?, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

/// One folder, possibly several spellings of its path. A bookmark hands back `/private/var/...`
/// where a stored path says `/var/...`, and the two strings have to be known as the same folder:
/// the app decides "this is the folder we were suspended on" and files the unwritten-text mirrors
/// by this key, so an unresolved spelling would hide a folder's own recovery from itself.
enum NotesFolderIdentity {
    static func key(for path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return resolvingSymlinks(of: standardized) ?? standardized
    }

    /// Every key this folder can be named by, newest spelling first.
    static func allKeys(for path: String) -> [String] {
        let raw = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let resolved = resolvingSymlinks(of: raw), resolved != raw else { return [raw] }
        return [resolved, raw]
    }

    private static func resolvingSymlinks(of path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return (path as NSString).resolvingSymlinksInPath
    }
}

/// Where the notes folder lives, and how the app gets back into it after a relaunch.
/// The stored bookmark outranks the plain path because the bookmark is what can carry an access
/// grant; the path is the fallback for setups saved before bookmarks existed.
enum NotesFolderResolver {
    static func folderURL(store: SettingsStore, pathKey: String, bookmarkKey: String) -> URL? {
        let storedPath = store.string(forKey: pathKey) ?? ""
        guard let data = store.data(forKey: bookmarkKey) else {
            return url(for: storedPath)
        }

        var isStale = false
        guard let bookmarked = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return url(for: storedPath)
        }

        if isStale {
            refreshBookmark(for: bookmarked, store: store, bookmarkKey: bookmarkKey)
        }
        // A bookmark can point at a folder that has since gone away; the stored path is the older,
        // possibly still usable answer.
        return FileManager.default.fileExists(atPath: bookmarked.path) ? bookmarked : url(for: storedPath)
    }

    /// Remembers a folder the user picked. The security-scoped form is preferred; a plain bookmark
    /// is stored when the system refuses to grant a scope, which is normal outside a sandbox.
    static func storeBookmark(
        for url: URL,
        store: SettingsStore,
        pathKey: String,
        bookmarkKey: String
    ) {
        store.set(bookmarkData(for: url), forKey: bookmarkKey)
        store.set(url.path, forKey: pathKey)
    }

    static func bookmarkData(for url: URL) -> Data? {
        if let scoped = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            return scoped
        }
        return try? url.bookmarkData()
    }

    private static func refreshBookmark(for url: URL, store: SettingsStore, bookmarkKey: String) {
        guard let data = bookmarkData(for: url) else { return }
        store.set(data, forKey: bookmarkKey)
    }

    private static func url(for path: String) -> URL? {
        path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }
}
