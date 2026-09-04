import AppKit
import SwiftUI

/// The About settings tab in ding Settings.
///
/// Displays application metadata, dynamic version information, manual and automatic
/// update-checking controls, repository links, license information, and open-source acknowledgements.
struct AboutSettingsView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var updateChecker = UpdateChecker.shared

    private static let repoURL = URL(string: "https://github.com/rohpod/ding")!
    private static let licenseURL = URL(string: "https://github.com/rohpod/ding/blob/main/LICENSE")!

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        Form {
            // MARK: - App Identity Section
            Section {
                HStack(alignment: .center, spacing: 16) {
                    if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
                       let nsImage = NSImage(contentsOf: iconURL) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 56, height: 56)
                    } else if let icon = NSImage(named: NSImage.applicationIconName) {
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

                HStack {
                    Button(action: {
                        Task {
                            await updateChecker.checkForUpdate()
                        }
                    }) {
                        Text("Check Now")
                    }
                    .disabled(updateChecker.isChecking)

                    if updateChecker.isChecking {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.leading, 6)
                        Text("Checking for updates…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }

                updateStatusView
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
                Text("Built with Apple's SwiftNIO and swift-nio-imap (Apache 2.0).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Status View Helper

    @ViewBuilder
    private var updateStatusView: some View {
        if let result = updateChecker.lastResult {
            switch result {
            case .upToDate:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Up to date")
                        .foregroundColor(.primary)

                    if let lastDate = preferences.lastUpdateCheckDate {
                        Text("• Last checked \(Self.dateFormatter.string(from: lastDate))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

            case let .updateAvailable(_, latestVersion, releaseURL):
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.blue)
                    Text("Update available: \(latestVersion)")
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    Spacer()

                    Button("View on GitHub") {
                        NSWorkspace.shared.open(releaseURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

            case let .failed(reason):
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Couldn't check for updates")
                            .foregroundColor(.primary)

                        if let lastDate = preferences.lastUpdateCheckDate {
                            Text("• Last checked \(Self.dateFormatter.string(from: lastDate))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } else if let lastDate = preferences.lastUpdateCheckDate {
            Text("Last checked: \(Self.dateFormatter.string(from: lastDate))")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Text("No update checks performed yet.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
