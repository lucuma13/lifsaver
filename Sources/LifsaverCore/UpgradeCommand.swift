import Foundation

/// Best-effort guess at the upgrade command for this installation.
///
/// lifsaver ships through two channels that land identical files in
/// /Applications, but only the Homebrew cask leaves a Caskroom metadata
/// directory behind — its presence is what tells the channels apart.
/// A .pkg install has no package manager to invoke, so the hint downloads
/// the new installer directly; UpdateChecker fills in `{latest}` with the
/// release version once it is known.
/// True only when `path` is an existing *directory*: a plain file sitting at a
/// Caskroom path must not be read as a cask install.
public func directoryExistsOnDisk(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        && isDirectory.boolValue
}

private let caskrooms = [
    "/opt/homebrew/Caskroom/lifsaver",  // Apple silicon prefix
    "/usr/local/Caskroom/lifsaver",  // Intel prefix
]

public func lifsaverUpgradeCommand(
    directoryExists: (String) -> Bool = directoryExistsOnDisk
) -> String {
    if caskrooms.contains(where: directoryExists) {
        return "brew upgrade --cask lifsaver"
    }
    return "open https://github.com/lucuma13/lifsaver/releases/download/v{latest}/lifsaver_installer_macos.pkg"
}

/// Human-readable install channel for diagnostic reports, from the same
/// Caskroom signal the upgrade hint uses.
public func lifsaverInstallChannel(
    directoryExists: (String) -> Bool = directoryExistsOnDisk
) -> String {
    caskrooms.contains(where: directoryExists) ? "Homebrew cask" : "installer package or local build"
}
