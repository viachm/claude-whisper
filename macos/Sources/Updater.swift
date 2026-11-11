import AppKit
import CryptoKit
import Security

/// Checks GitHub for a newer release and installs it when asked: downloads the macOS zip, checks
/// its SHA-256 and code signature, then swaps the app bundle once this process has quit and opens
/// the new one. These are the only network requests the app makes itself, all to GitHub, and only
/// when "Check for Updates…" is clicked.
final class Updater {
    /// Shown in the menu: "Update to 0.1.10…" once a check found one.
    private(set) var available: Release?
    var onChange: (() -> Void)?
    private var busy = false

    static var current: AppVersion {
        AppVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") ?? AppVersion("0")!
    }

    /// From the menu: says so when there is nothing new or the check failed.
    func check() {
        guard !busy else { return }
        busy = true
        var request = URLRequest(url: Release.latestURL, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Claude-Whisper/\(Self.current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = status == 200 ? data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) } : nil
            DispatchQueue.main.async { [self] in
                busy = false
                guard let release, let latest = release.version else {
                    Log.write("update check failed: \(error?.localizedDescription ?? "HTTP \(status)")")
                    alert("Couldn't check for updates", "GitHub didn't answer. Try again later, or see the releases page.", release: nil)
                    return
                }
                Log.write("update check: latest \(latest), running \(Self.current)")
                available = latest > Self.current ? release : nil
                onChange?()
                offer()
            }
        }.resume()
    }

    /// The menu item while an update is known: asks, then installs.
    func offer() {
        guard let release = available, let latest = release.version else {
            return alert("Claude Whisper is up to date", "Version \(Self.current) is the latest.", release: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude Whisper \(latest) is available"
        alert.informativeText = "You have \(Self.current). Claude Whisper downloads it from GitHub, quits and opens the new version."
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(release.page)
        default: break
        }
    }

    private func install(_ release: Release) {
        guard !busy else { return }
        guard let asset = release.asset(named: Release.macAsset) else {
            return fail("The release has no \(Release.macAsset).", release)
        }
        let destination = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            return fail("Claude Whisper can't replace itself in \(destination.deletingLastPathComponent().path).", release)
        }
        busy = true
        Log.write("downloading \(asset.url.absoluteString)")
        URLSession.shared.downloadTask(with: asset.url) { file, response, error in
            let result: Result<URL, UpdateError>
            if let file, (response as? HTTPURLResponse)?.statusCode == 200 {
                result = Result { try Self.unpack(file, asset: asset) }.mapError { $0 as? UpdateError ?? UpdateError($0.localizedDescription) }
            } else {
                result = .failure(UpdateError("The download failed: \(error?.localizedDescription ?? "no file")."))
            }
            DispatchQueue.main.async { [self] in
                busy = false
                switch result {
                case .success(let app): relaunch(into: app, replacing: destination)
                case .failure(let error): fail(error.message, release)
                }
            }
        }.resume()
    }

    struct UpdateError: Error { let message: String; init(_ message: String) { self.message = message } }

    /// Runs off the main thread: checks the zip, unpacks it and checks the app inside.
    static func unpack(_ zip: URL, asset: Release.Asset) throws -> URL {
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        if let expected = Release.sha256(fromDigest: asset.digest) {
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == expected else { throw UpdateError("The download is damaged (its SHA-256 doesn't match GitHub's).") }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("claude-whisper-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        let app = folder.appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        guard ditto.terminationStatus == 0, let bundle = Bundle(url: app) else { throw UpdateError("The zip didn't contain the app.") }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else { throw UpdateError("The zip contains a different app.") }
        try checkSignature(of: app)
        return app
    }

    /// The new app must be validly signed. When this one is signed with an Apple-issued
    /// certificate (a Developer ID), the new one must be signed by the same team.
    static func checkSignature(of app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("The new app couldn't be read.")
        }
        var requirement: SecRequirement?
        if let team = ownTeam() {
            let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
                throw UpdateError("The signature check couldn't be set up.")
            }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        if requirement != nil && status == errSecCSReqFailed {
            throw UpdateError("The new app isn't signed by the same developer as this one.")
        }
        guard status == errSecSuccess else { throw UpdateError("The new app's signature isn't valid (\(status)).") }
    }

    private static func ownTeam() -> String? {
        var me: SecCode?, staticMe: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopySigningInformation(staticMe, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// A small script waits for this process to quit, puts the new app in place of the old one
    /// (restoring the old one if that fails) and opens it.
    private func relaunch(into app: URL, replacing destination: URL) {
        let script = """
            pid="$1"; new="$2"; dest="$3"; old="$dest.old-$$"
            while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
            if mv "$dest" "$old"; then
              if mv "$new" "$dest"; then rm -rf "$old"; else mv "$old" "$dest"; fi
            fi
            xattr -dr com.apple.quarantine "$dest" 2>/dev/null
            open "$dest"
            """
        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = ["-c", script, "swap", String(ProcessInfo.processInfo.processIdentifier), app.path, destination.path]
        do {
            try swap.run()
        } catch {
            return fail("Couldn't start the update: \(error.localizedDescription)", available)
        }
        Log.write("installing the update and relaunching")
        NSApp.terminate(nil)
    }

    private func fail(_ message: String, _ release: Release?) {
        Log.write("update failed: \(message)")
        alert("The update wasn't installed", message + " You can download it from GitHub instead.", release: release)
    }

    private func alert(_ title: String, _ text: String, release: Release?) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Releases Page")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(release?.page ?? URL(string: "https://github.com/viachm/claude-whisper/releases/latest")!)
        }
    }
}
