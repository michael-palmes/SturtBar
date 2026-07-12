// UpdateInstaller.swift: downloads, verifies and installs a release in place.
//
// Verification is fail-closed and layered: exact asset size, SHA-256 against the release's
// published checksum (plus GitHub's own asset digest when present), code signature pinned to the
// running app's own Team ID and bundle id, a Gatekeeper assessment (offline via the stapled
// ticket), and an exact version match. Only then does the bundle swap happen. Elevation is a
// single file swap through the standard macOS authorisation dialog (Admin By Request friendly);
// the app itself never runs privileged. Staging lives under Application Support, not TMPDIR, so
// the reveal flow never touches TCC-protected folders and a verified download survives for a
// manual install.

import Foundation
import Security
import SturtBarCore

// MARK: - Types

enum UpdateInstallStage {
    case downloading
    case installing
}

enum UpdateRevealReason: Equatable {
    /// The swap needs administrator rights the user could not (or chose not to) provide.
    case needsAdministrator
    /// Running from a DMG, translocated path, temp dir or Downloads; in-place update is wrong.
    case notInApplications
    /// The running build has no Team ID to pin against (dev or ad-hoc build); never auto-swap.
    case unsignedBuild
}

enum UpdateInstallError: Error, Equatable {
    case stagingFailed
    case assetTooLarge
    case downloadFailed
    case unexpectedAssetSize
    case checksumUnavailable
    case checksumMismatch
    case extractionFailed
    case wrongBundle
    case versionMismatch
    case signatureVerificationFailed
    case notarisationRejected
    case swapFailed

    var userMessage: String {
        switch self {
        case .stagingFailed:
            "The update could not be staged on disk. Check free space and try again."
        case .assetTooLarge, .unexpectedAssetSize:
            "The downloaded file did not match the release. Nothing was installed."
        case .downloadFailed:
            "The update could not be downloaded. Check your connection and try again."
        case .checksumUnavailable, .checksumMismatch:
            "The download failed its integrity check. Nothing was installed."
        case .extractionFailed:
            "The downloaded archive could not be unpacked. Nothing was installed."
        case .wrongBundle, .versionMismatch, .signatureVerificationFailed, .notarisationRejected:
            "The downloaded app failed verification. Nothing was installed."
        case .swapFailed:
            "The new version could not be moved into place. Nothing was changed."
        }
    }
}

enum UpdateInstallResult: Equatable {
    case installed
    case revealedForManualInstall(reason: UpdateRevealReason, appURL: URL)
    case failed(UpdateInstallError)
}

/// Seam for UpdateStore; tests inject a fake.
protocol UpdateInstalling: Sendable {
    func install(
        release: ReleaseInfo,
        onStage: @escaping @Sendable (UpdateInstallStage) -> Void) async -> UpdateInstallResult
}

// MARK: - Installer

struct UpdateInstaller: UpdateInstalling {
    /// Well above any real SturtBar release (~5 MB); caps both download and decompression exposure.
    static let maxAssetBytes = 100 * 1024 * 1024
    static let expectedBundleID = "com.michaelpalmes.sturtbar"

    /// The bundle being replaced; injectable for tests.
    var targetBundleURL: URL = Bundle.main.bundleURL

    /// Ephemeral: no cookies, no shared cache. Asset downloads follow GitHub's 302 to the
    /// disclosed release-assets host.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private static let log = SturtBarLog.logger("updater")

    // MARK: Install flow

    func install(
        release: ReleaseInfo,
        onStage: @escaping @Sendable (UpdateInstallStage) -> Void) async -> UpdateInstallResult
    {
        onStage(.downloading)
        guard release.zipAssetSize <= Self.maxAssetBytes else { return .failed(.assetTooLarge) }
        guard let staging = Self.makeStagingDirectory(version: release.version) else {
            return .failed(.stagingFailed)
        }

        // Download and integrity-check the zip before anything touches it.
        guard let zipURL = await Self.downloadAsset(
            from: release.zipAssetURL,
            named: release.zipAssetName,
            into: staging)
        else { return .failed(.downloadFailed) }
        guard Self.fileSize(of: zipURL) == release.zipAssetSize else {
            return .failed(.unexpectedAssetSize)
        }
        switch await Self.verifyChecksum(of: zipURL, release: release) {
        case .success:
            break
        case let .failure(error):
            return .failed(error)
        }

        // Unpack and verify the app itself.
        let appURL = staging.appendingPathComponent("SturtBar.app", isDirectory: true)
        guard await Self.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, staging.path]) == 0,
              FileManager.default.fileExists(atPath: appURL.path)
        else { return .failed(.extractionFailed) }
        try? FileManager.default.removeItem(at: zipURL)

        let info = Self.bundleInfo(at: appURL)
        guard info.bundleID == Self.expectedBundleID else { return .failed(.wrongBundle) }
        guard let versionString = info.version,
              SemanticVersion(string: versionString) == release.version
        else { return .failed(.versionMismatch) }

        let ownTeam = Self.ownTeamIdentifier()
        if let ownTeam {
            guard Self.verifyCodeSignature(appURL: appURL, bundleID: Self.expectedBundleID, teamID: ownTeam)
            else { return .failed(.signatureVerificationFailed) }
        }
        // Gatekeeper assessment; offline thanks to the stapled notarisation ticket.
        guard await Self.run("/usr/sbin/spctl", ["--assess", "--type", "execute", appURL.path]) == 0 else {
            return .failed(.notarisationRejected)
        }
        // No Team ID to pin against means we never swap automatically, verified or not.
        if ownTeam == nil {
            return .revealedForManualInstall(reason: .unsignedBuild, appURL: appURL)
        }
        guard Self.classifyBundleLocation(
            path: self.targetBundleURL.path,
            homeDirectory: NSHomeDirectory()) == .installInPlace
        else {
            return .revealedForManualInstall(reason: .notInApplications, appURL: appURL)
        }

        // Swap: atomic replace first, one elevated attempt on permission failure.
        onStage(.installing)
        do {
            _ = try FileManager.default.replaceItemAt(self.targetBundleURL, withItemAt: appURL)
        } catch {
            Self.log.info("Atomic replace failed; attempting elevated swap")
            let status = await Self.runElevatedSwap(
                targetPath: self.targetBundleURL.path,
                stagedPath: appURL.path)
            guard status == 0 else {
                // Declined or failed authorisation: the verified app stays staged for retry.
                return .revealedForManualInstall(reason: .needsAdministrator, appURL: appURL)
            }
        }
        Self.spawnRelauncher(
            bundlePath: self.targetBundleURL.path,
            parentPID: ProcessInfo.processInfo.processIdentifier)
        try? FileManager.default.removeItem(at: staging)
        return .installed
    }

    // MARK: Staging

    /// Fresh per-version staging dir under Application Support (0700), replacing any leftover.
    private static func makeStagingDirectory(version: SemanticVersion) -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support
            .appendingPathComponent("SturtBar", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
            .appendingPathComponent("\(version)", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return dir
        } catch {
            return nil
        }
    }

    /// Best-effort cleanup of all staged updates; called by the store once an offer is gone.
    static func removeStagedUpdates() {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let dir = support
            .appendingPathComponent("SturtBar", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Download + checksum

    private static func downloadAsset(from url: URL, named name: String, into dir: URL) async -> URL? {
        do {
            let (tempURL, response) = try await Self.session.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                try? FileManager.default.removeItem(at: tempURL)
                return nil
            }
            let destination = dir.appendingPathComponent(name, isDirectory: false)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// The published .sha256 asset is required (fail closed); GitHub's own digest, when present,
    /// must agree as well.
    private static func verifyChecksum(
        of zipURL: URL,
        release: ReleaseInfo) async -> Result<Void, UpdateInstallError>
    {
        guard let checksumURL = release.checksumAssetURL else { return .failure(.checksumUnavailable) }
        guard let contents = await Self.fetchSmallText(from: checksumURL) else {
            return .failure(.checksumUnavailable)
        }
        guard let expected = UpdateChecksum.expectedHex(inChecksumFile: contents, assetName: release.zipAssetName)
        else { return .failure(.checksumUnavailable) }
        if let digest = release.zipAssetDigest, let apiHex = UpdateChecksum.normalisedHex(digest),
           apiHex != expected
        {
            return .failure(.checksumMismatch)
        }
        guard (try? UpdateChecksum.matches(fileURL: zipURL, expectedHex: expected)) == true else {
            return .failure(.checksumMismatch)
        }
        return .success(())
    }

    private static func fetchSmallText(from url: URL) async -> String? {
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= 4096
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func fileSize(of url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { ($0[.size] as? NSNumber)?.intValue }
    }

    // MARK: Verification

    /// The running app's Team ID; nil for dev and ad-hoc builds (which then never auto-swap).
    static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode
        else { return nil }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              team.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return nil }
        return team
    }

    /// Strict static validity pinned to the expected bundle id and the running app's Team ID.
    static func verifyCodeSignature(appURL: URL, bundleID: String, teamID: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return false }
        let requirementString =
            "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementString as CFString,
            SecCSFlags(),
            &requirement) == errSecSuccess,
            let requirement
        else { return false }
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }

    static func bundleInfo(at appURL: URL) -> (bundleID: String?, version: String?) {
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return (nil, nil) }
        return (
            plist["CFBundleIdentifier"] as? String,
            plist["CFBundleShortVersionString"] as? String)
    }

    // MARK: Location

    enum UpdateInstallLocation: Equatable {
        case installInPlace
        case revealOnly
    }

    /// Pure classification of where the running bundle lives. Translocated, mounted-volume and
    /// temp/Downloads locations degrade to the reveal flow; anywhere else swaps in place.
    static func classifyBundleLocation(path: String, homeDirectory: String) -> UpdateInstallLocation {
        if path.contains("/AppTranslocation/") { return .revealOnly }
        if path.hasPrefix("/Volumes/") { return .revealOnly }
        for tempPrefix in ["/private/var/folders/", "/var/folders/", "/tmp/", "/private/tmp/"]
            where path.hasPrefix(tempPrefix)
        {
            return .revealOnly
        }
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        if path.hasPrefix(home + "/Downloads/") { return .revealOnly }
        return .installInPlace
    }

    // MARK: Swap + relaunch

    /// One elevated attempt via the standard macOS authorisation dialog. The script swaps the
    /// bundle and restores the old copy if the new one cannot be moved in. Exit status 0 = done;
    /// anything else (including a cancelled dialog) leaves the target untouched or restored.
    static func elevatedSwapScript(targetPath: String, stagedPath: String) -> String {
        let target = Self.shellQuoted(targetPath)
        let staged = Self.shellQuoted(stagedPath)
        return """
        OLD=\(target)'.pre-update'; /bin/rm -rf "$OLD" && /bin/mv \(target) "$OLD" || exit 1; \
        if /bin/mv \(staged) \(target); then /bin/rm -rf "$OLD"; exit 0; \
        else /bin/mv "$OLD" \(target); exit 1; fi
        """
    }

    private static func runElevatedSwap(targetPath: String, stagedPath: String) async -> Int32 {
        let shell = Self.elevatedSwapScript(targetPath: targetPath, stagedPath: stagedPath)
        let script = "do shell script \(Self.appleScriptQuoted(shell)) with administrator privileges"
        return await Self.run("/usr/bin/osascript", ["-e", script])
    }

    /// Waits for this process to exit, then opens the swapped bundle. Detached so it survives
    /// our termination.
    private static func spawnRelauncher(bundlePath: String, parentPID: Int32) {
        let command = "while /bin/kill -0 \(parentPID) 2>/dev/null; do /bin/sleep 0.2; done; "
            + "/usr/bin/open \(Self.shellQuoted(bundlePath))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: Helpers

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuoted(_ value: String) -> String {
        "\""
            + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    private static func run(_ executable: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
    }
}
