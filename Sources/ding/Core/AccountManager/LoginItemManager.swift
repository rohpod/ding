import Foundation
import os
import ServiceManagement

/// Errors specific to login item management.
public enum LoginItemError: LocalizedError, Sendable {
    case requiresAppBundle

    public var errorDescription: String? {
        switch self {
        case .requiresAppBundle:
            return "Open at login requires ding to be run from an application bundle (ding.app)."
        }
    }
}

/// Manages registering and unregistering ding as a macOS login item using `SMAppService`.
///
/// ## Modern Login Item Management (`SMAppService` vs `SMLoginItemSetEnabled`)
/// Starting with macOS 13 (Ventura), Apple deprecated `SMLoginItemSetEnabled` and introduced `SMAppService`.
/// `SMAppService.mainApp` provides a cleaner, modern API with several key advantages:
/// 1. It directly manages the main application bundle without requiring a nested helper application
///    in `Contents/Library/LoginItems`.
/// 2. It integrates natively with the modern macOS "Login Items & Extensions" interface in System Settings,
///    allowing users to see ding clearly with accurate ownership attribution.
/// 3. It exposes explicit registration status (`.enabled`, `.notRegistered`, `.requiresApproval`, `.notFound`)
///    rather than an opaque boolean, enabling robust error detection and handling.
@MainActor
public final class LoginItemManager: Sendable {
    private static let logger = Logger(subsystem: "com.ding.mac", category: "LoginItem")

    /// Shared singleton instance of `LoginItemManager`.
    public static let shared = LoginItemManager()

    private let appService: SMAppService

    /// Indicates whether the current process is executing within a valid `.app` application bundle.
    public static var isRunningInAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Initializes a new login item manager.
    ///
    /// - Parameter appService: The `SMAppService` instance to manage. Defaults to `SMAppService.mainApp`.
    public init(appService: SMAppService = .mainApp) {
        self.appService = appService
    }

    /// Indicates whether ding is currently registered to launch at login with the system.
    ///
    /// This checks the live `SMAppService.status` rather than a cached local preference,
    /// ensuring that manual changes made by the user in macOS System Settings are accurately reflected.
    public var isLoginItemEnabled: Bool {
        guard Self.isRunningInAppBundle else {
            return false
        }
        return appService.status == .enabled
    }

    /// Current status of the login item service in macOS.
    public var status: SMAppService.Status {
        guard Self.isRunningInAppBundle else {
            return .notRegistered
        }
        return appService.status
    }

    /// Registers ding to open automatically at login.
    ///
    /// - Throws: `LoginItemError.requiresAppBundle` if run outside an app bundle, or system errors if registration fails.
    public func enableLoginItem() throws {
        guard Self.isRunningInAppBundle else {
            Self.logger.error("Failed to register login item: process is not running within an .app bundle.")
            throw LoginItemError.requiresAppBundle
        }

        Self.logger.info("Attempting to register login item via SMAppService.mainApp.")
        do {
            try appService.register()
            Self.logger.info("Successfully registered login item.")
        } catch {
            Self.logger.error("Failed to register login item: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Unregisters ding from opening at login.
    ///
    /// - Throws: `LoginItemError.requiresAppBundle` if run outside an app bundle, or system errors if unregistration fails.
    public func disableLoginItem() throws {
        guard Self.isRunningInAppBundle else {
            Self.logger.error("Failed to unregister login item: process is not running within an .app bundle.")
            throw LoginItemError.requiresAppBundle
        }

        Self.logger.info("Attempting to unregister login item via SMAppService.mainApp.")
        do {
            try appService.unregister()
            Self.logger.info("Successfully unregistered login item.")
        } catch {
            Self.logger.error("Failed to unregister login item: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
