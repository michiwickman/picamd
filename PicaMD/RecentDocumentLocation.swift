import Foundation

/// Where a recent document lives, worked out from its path alone: the
/// welcome window's subtitle ("Documents ▸ Travel", "iCloud Drive") and
/// the store's decision whether a missing file is gone for good or only
/// on a disk or cloud account that isn't there right now.
///
/// Pure string logic with the home folder passed in, so tests don't
/// depend on the machine they run on.
enum RecentDocumentLocation {
    static let separator = " ▸ "
    /// Longer folder chains keep their first component (the location) and
    /// the last two, with "…" between them, so the subtitle stays on one
    /// line in the 360 pt recents column. The tooltip has the full path.
    static let maxComponents = 3

    /// The folder a location is measured from and the name shown for it.
    /// `label` is nil for the home folder: "Documents ▸ Travel" rather
    /// than "Home ▸ Documents ▸ Travel".
    struct Root: Equatable {
        let path: String
        let label: String?
    }

    /// The location root a path belongs to: iCloud Drive, a File Provider
    /// folder in `~/Library/CloudStorage` (OneDrive, Google Drive, …), a
    /// volume under `/Volumes`, the home folder, or the startup disk.
    static func root(of path: String, home: String, startupVolumeName: String) -> Root {
        let home = trimmed(home)
        let iCloud = home + "/Library/Mobile Documents/com~apple~CloudDocs"
        if path == iCloud || path.hasPrefix(iCloud + "/") {
            return Root(path: iCloud, label: "iCloud Drive")
        }
        let cloudStorage = home + "/Library/CloudStorage/"
        if path.hasPrefix(cloudStorage),
           let folder = path.dropFirst(cloudStorage.count).split(separator: "/").first {
            return Root(path: cloudStorage + folder, label: cloudStorageName(String(folder)))
        }
        if path.hasPrefix("/Volumes/"),
           let volume = path.dropFirst("/Volumes/".count).split(separator: "/").first {
            return Root(path: "/Volumes/" + volume, label: String(volume))
        }
        if path == home || path.hasPrefix(home + "/") {
            return Root(path: home, label: nil)
        }
        return Root(path: "/", label: startupVolumeName)
    }

    /// Subtitle for a recent document: its folder relative to the
    /// location root, components joined with " ▸ ".
    static func subtitle(forFile path: String, home: String, startupVolumeName: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        let root = root(of: folder, home: home, startupVolumeName: startupVolumeName)
        let relative = folder == root.path
            ? []
            : folder.dropFirst(trimmed(root.path).count).split(separator: "/").map(String.init)
        var parts = (root.label.map { [$0] } ?? []) + relative
        if parts.isEmpty { return "Home" }
        if parts.count > maxComponents {
            parts = [parts[0], "…"] + parts.suffix(2)
        }
        return parts.joined(separator: separator)
    }

    /// True for anything inside a Trash: `~/.Trash`, a volume's
    /// `.Trashes`, or iCloud Drive's `.Trash`. Such a file still exists,
    /// so an existence check alone kept trashed documents in the list.
    static func isInTrash(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// Readable name for a `~/Library/CloudStorage` folder, which File
    /// Provider names "<Provider>-<Account>" with the spaces removed:
    /// "OneDrive-Persönlich" → "OneDrive – Persönlich",
    /// "OneDrive-MusterfirmaGrün" → "OneDrive – Musterfirma Grün",
    /// "GoogleDrive-me@example.com" → "Google Drive – me@example.com".
    static func cloudStorageName(_ folder: String) -> String {
        let pieces = folder.split(separator: "-", maxSplits: 1).map(String.init)
        let provider = providerNames[pieces[0]] ?? pieces[0]
        guard pieces.count == 2, !pieces[1].isEmpty else { return provider }
        let account = pieces[1].contains("@") ? pieces[1] : splitCamelCase(pieces[1])
        return "\(provider) – \(account)"
    }

    private static let providerNames = [
        "GoogleDrive": "Google Drive",
    ]

    /// "MusterfirmaGrün" → "Musterfirma Grün".
    /// Works on Characters, so a decomposed "ü" (as the file system
    /// stores it) stays one letter.
    private static func splitCamelCase(_ text: String) -> String {
        var result = ""
        var previous: Character?
        for character in text {
            if let previous, previous.isLowercase, character.isUppercase {
                result.append(" ")
            }
            result.append(character)
            previous = character
        }
        return result
    }

    private static func trimmed(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
