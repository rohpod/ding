import SwiftUI
import UserNotifications

/// The General settings tab in ding Settings.
///
/// Configures default synchronization frequencies, notification click behavior,
/// menu bar presence, startup behavior, and application metadata.
struct GeneralSettingsView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    private let loginItemManager = LoginItemManager.shared
    private let notificationManager = NotificationPermissionManager.shared

    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var notificationErrorMessage: String?
    @State private var loginItemErrorMessage: String?

    var body: some View {
        Form {
            // MARK: - Sync Section
            Section("Sync") {
                Picker("Default sync frequency", selection: $preferences.defaultSyncFrequency) {
                    ForEach(SyncFrequency.generalOptions, id: \.self) { frequency in
                        Text(frequency.displayName).tag(frequency)
                    }
                }
            }

            // MARK: - Notifications Section
            Section("Notifications") {
                Picker("When notification is clicked", selection: $preferences.defaultNotificationClickBehavior) {
                    ForEach(NotificationClickBehavior.generalOptions, id: \.self) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }

                HStack {
                    Text("Notification permission")
                    Spacer()
                    permissionIndicator
                    if notificationStatus == .notDetermined {
                        Button("Request Permission") {
                            Task {
                                await handleRequestNotificationPermission()
                            }
                        }
                    } else if notificationStatus == .denied {
                        Button("Open Notification Settings") {
                            notificationManager.openSystemSettingsForNotifications()
                        }
                    }
                }

                if let error = notificationErrorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // MARK: - Menu Bar Section
            Section("Menu Bar") {
                Toggle("Show menu bar icon", isOn: $preferences.isMenuBarIconVisible)

                if !preferences.isMenuBarIconVisible {
                    Text("You can reopen ding by launching it again from Applications.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // MARK: - Startup Section
            Section("Startup") {
                Toggle("Open ding at login", isOn: Binding(
                    get: { preferences.isOpenAtLoginEnabled },
                    set: { newValue in
                        handleLoginItemToggle(enable: newValue)
                    }
                ))

                if let errorMessage = loginItemErrorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            // MARK: - About Section
            Section("About") {
                HStack {
                    Text("ding")
                    Spacer()
                    if let repoURL = URL(string: "https://github.com/rohpod/ding") {
                        Link("View on GitHub", destination: repoURL)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshNotificationStatus()
            syncLoginItemStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await refreshNotificationStatus()
                syncLoginItemStatus()
            }
        }
    }

    // MARK: - Private Helpers

    private var isNotificationAllowed: Bool {
        notificationStatus == .authorized || notificationStatus == .provisional
    }

    @ViewBuilder
    private var permissionIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .foregroundColor(.secondary)
        }
    }

    private var statusColor: Color {
        switch notificationStatus {
        case .authorized, .provisional:
            return .green
        case .denied:
            return .red
        case .notDetermined:
            return .secondary
        @unknown default:
            return .secondary
        }
    }

    private var statusText: String {
        switch notificationStatus {
        case .authorized, .provisional:
            return "Allowed"
        case .denied:
            return "Not allowed"
        case .notDetermined:
            return "Not determined"
        @unknown default:
            return "Unknown"
        }
    }

    private func refreshNotificationStatus() async {
        notificationStatus = await notificationManager.currentAuthorizationStatus()
    }

    private func syncLoginItemStatus() {
        preferences.isOpenAtLoginEnabled = loginItemManager.isLoginItemEnabled
    }

    private func handleRequestNotificationPermission() async {
        notificationErrorMessage = nil
        do {
            _ = try await notificationManager.requestAuthorization()
            await refreshNotificationStatus()
        } catch {
            notificationErrorMessage = error.localizedDescription
            await refreshNotificationStatus()
        }
    }

    private func handleLoginItemToggle(enable: Bool) {
        loginItemErrorMessage = nil
        do {
            if enable {
                try loginItemManager.enableLoginItem()
            } else {
                try loginItemManager.disableLoginItem()
            }
            preferences.isOpenAtLoginEnabled = enable
        } catch {
            loginItemErrorMessage = "Failed to update login item: \(error.localizedDescription)"
            preferences.isOpenAtLoginEnabled = loginItemManager.isLoginItemEnabled
        }
    }
}
