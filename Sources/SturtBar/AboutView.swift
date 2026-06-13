// AboutView.swift — the About window content (the Logbook's title page).
//
// Plain SwiftUI panel in a lazily-created window (WindowsController) instead of the legacy
// `orderFrontStandardAboutPanel` + focus-ring surgery (Sources/CodexBar/About.swift). Version
// info comes from the bundle and degrades to "dev" under `swift run`, where no Info.plist
// exists. The About box is the one surface BRAND.md lets the Keeper soak in theme: warm system
// serif for the voice, the lamp accent used once, true history only.

import AppKit
import SwiftUI

struct AboutView: View {
    /// BRAND.md §4.2 `lamp` (#D97757): the one warm accent, used once on this surface.
    private static let lamp = Color(red: 0.851, green: 0.467, blue: 0.341)

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            Text("SturtBar")
                .font(.system(.title2, design: .serif).weight(.semibold))

            Text("Version \(Self.versionString())")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("First to shine, last to sleep.")
                .font(.system(.callout, design: .serif).italic())
                .foregroundStyle(Self.lamp)
                .padding(.top, 2)

            Text(
                "The 17th light raised on this coast, and the first in South Australia. "
                    + "Demanned 1992. Re-manned, reluctantly, by software.")
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            // BRAND.md §3.3 trust moment: themed surface, literal claim.
            Text(
                "The Keeper watches the water, not you. No telemetry, no analytics; "
                    + "your keys stay in the keychain and are never altered.")
                .font(.system(.footnote, design: .serif))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            Divider()
                .padding(.vertical, 6)

            Link(
                "github.com/michael-palmes/SturtBar",
                destination: URL(string: "https://github.com/michael-palmes/SturtBar")!)
                .font(.footnote)

            Text("No. 17 · MIT License · Zero third-party dependencies")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        }
        .padding(24)
        .frame(width: 320)
    }

    static func versionString() -> String {
        self.versionString(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }

    /// "1.2 (34)" / "1.2" / "dev" — pure so the nil fallbacks are testable without a bundle.
    nonisolated static func versionString(version: String?, build: String?) -> String {
        guard let version, !version.isEmpty else { return "dev" }
        guard let build, !build.isEmpty else { return version }
        return "\(version) (\(build))"
    }
}

// MARK: - Previews

#if DEBUG
#Preview("About") {
    AboutView()
}
#endif
