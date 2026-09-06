import AppKit
import os

/// Helper responsible for locating and loading the menu bar template icon.
public enum MenuBarIconLoader {
    private static let logger = Logger(subsystem: DingLog.subsystem, category: "MenuBarIcon")

    /// Loads the custom menu bar template icon asset, configuring it for dynamic macOS tinting.
    ///
    /// Supports loading from the `.app` bundle (`Bundle.main`), the SwiftPM resource bundle (`Bundle.module`),
    /// or via standard named lookup, with a graceful fallback to the SF Symbol "envelope".
    public static func loadMenuBarIcon() -> NSImage {
        let resourceName = "MenuBarIconTemplate"

        // 1. Attempt loading directly from the app bundle's Contents/Resources directory
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            logger.info("Loaded menu bar icon from app bundle: \(url.path, privacy: .public)")
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 16)
            return image
        }
        logger.debug("Menu bar icon not found in Bundle.main (bundleURL: \(Bundle.main.bundleURL.path, privacy: .public))")

        // 2. Attempt loading from the SwiftPM resource bundle (used during unbundled runs and development)
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: resourceName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            logger.info("Loaded menu bar icon from Bundle.module: \(url.path, privacy: .public)")
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 16)
            return image
        }
        logger.debug("Menu bar icon not found in Bundle.module")
        #endif

        // 3. Attempt loading from the embedded SwiftPM resource bundle in Contents/Resources/
        if let resourceURL = Bundle.main.resourceURL {
            let embeddedBundlePath = resourceURL.appendingPathComponent("ding_ding.bundle")
            if let resourceBundle = Bundle(url: embeddedBundlePath),
               let url = resourceBundle.url(forResource: resourceName, withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                logger.info("Loaded menu bar icon from embedded resource bundle: \(url.path, privacy: .public)")
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 16)
                return image
            }
        }

        // 4. Attempt loading via standard named image lookup
        if let image = NSImage(named: NSImage.Name(resourceName)) {
            logger.info("Loaded menu bar icon via NSImage(named:) lookup.")
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 16)
            return image
        }

        // 5. Safe fallback: SF Symbol "envelope"
        logger.warning("MenuBarIconTemplate image asset not found; falling back to SF Symbol envelope.")
        let fallback = NSImage(
            systemSymbolName: "envelope",
            accessibilityDescription: "ding Mail Notification"
        ) ?? NSImage()
        fallback.isTemplate = true
        return fallback
    }
}
