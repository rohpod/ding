import AppKit
import SwiftUI

/// The About settings tab in ding Settings.
///
/// Displays application metadata, dynamic version information, manual and automatic
/// update-checking controls, repository links, license information, and open-source acknowledgements.
struct AboutSettingsView: View {
    @ObservedObject private var preferences = AppPreferences.shared

    private static let repoURL = URL(string: "https://github.com/rohpod/ding")!
    private static let licenseURL = URL(string: "https://github.com/rohpod/ding/blob/main/LICENSE")!

    /// The app icon from the bundle's `.icns`. Resolved per view rather than cached statically so the image is
    /// released along with the Settings window.
    private var appIcon: NSImage? {
        NSImage(named: NSImage.applicationIconName)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    var body: some View {
        Form {
            // MARK: - App Identity Section
            Section {
                HStack(alignment: .center, spacing: 16) {
                    if let icon = appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 56, height: 56)
                    } else {
                        Image(systemName: "envelope.badge.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.accentColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("ding")
                            .font(.title2)
                            .fontWeight(.bold)

                        Text("Version \(appVersion)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("A lightweight, native macOS menu bar mail notification utility. Open-source, fast, and stays out of your way.")
                            .font(.callout)
                            .foregroundColor(.primary)
                            .padding(.top, 2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            // MARK: - Updates Section
            Section("Updates") {
                Toggle("Automatically check for updates", isOn: $preferences.isAutomaticUpdateCheckEnabled)
                Toggle("Automatically download and install updates", isOn: $preferences.isAutomaticUpdateInstallEnabled)

                HStack {
                    Button("Check for Updates…") {
                        SparkleUpdateManager.shared.checkForUpdates()
                    }

                    Spacer()
                }
            }

            // MARK: - Links & Information
            Section("Project & License") {
                HStack {
                    Text("Source Code")
                    Spacer()
                    Link("View on GitHub", destination: Self.repoURL)
                }

                HStack {
                    Text("License")
                    Spacer()
                    Link("MIT License", destination: Self.licenseURL)
                }
            }

            // MARK: - Acknowledgements Section
            Section("Acknowledgements") {
                Text("Built with Apple's SwiftNIO, swift-nio-imap and swift-nio-ssl (Apache 2.0; includes BoringSSL), Sparkle (MIT) and KeyboardShortcuts by Sindre Sorhus (MIT).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
