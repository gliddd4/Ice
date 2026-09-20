//
//  Wallpaper.swift
//  Ice
//
//  Reconstructed from the compiled binary of the 2026-09-02 build.
//  Recovered API surface:
//    enum Wallpaper
//      static func applicationSupportDirectory() -> URL?
//      static func generateToken() -> String
//      static func saveWallpaper(_ image: NSImage) -> URL?
//      static func set(_ url: URL, screen: NSScreen) throws
//    enum WallpaperError
//
//  Recovered string literals:
//    "Error while obtaining the wallpaper image."
//    "Error while setting wallpaper: "
//

import Cocoa

/// An error that can occur while managing the desktop wallpaper.
enum WallpaperError: Error {
    /// The wallpaper image could not be obtained.
    case failedToObtainImage

    /// The wallpaper could not be set.
    case failedToSetWallpaper(underlying: Error)
}

extension WallpaperError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .failedToObtainImage:
            "Error while obtaining the wallpaper image."
        case .failedToSetWallpaper(let underlying):
            "Error while setting wallpaper: \(underlying.localizedDescription)"
        }
    }
}

/// A namespace for the wallpaper management helpers used by the transparent
/// menu bar backdrop.
enum Wallpaper {
    /// The number of characters in a generated token.
    private static let tokenLength = 16

    /// The alphabet used to generate file name tokens.
    private static let tokenAlphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

    /// Returns the directory where managed wallpaper images are stored,
    /// creating it if necessary.
    static func applicationSupportDirectory() -> URL? {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let directory = base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Ice", isDirectory: true)
            .appendingPathComponent("Wallpapers", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            Logger.wallpaper.error("Error creating wallpaper directory: \(error)")
            return nil
        }

        return directory
    }

    /// Generates a random token used to name managed wallpaper files.
    static func generateToken() -> String {
        String((0..<tokenLength).compactMap { _ in tokenAlphabet.randomElement() })
    }

    /// Writes the given image to the application support directory as a PNG.
    ///
    /// - Returns: The URL of the written file, or `nil` if the image could not be saved.
    static func saveWallpaper(_ image: NSImage) -> URL? {
        guard
            let directory = applicationSupportDirectory(),
            let data = image.pngData
        else {
            return nil
        }

        let url = directory
            .appendingPathComponent(generateToken())
            .appendingPathExtension("png")

        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Logger.wallpaper.error("Error saving wallpaper: \(error)")
            return nil
        }
    }

    /// Sets the image at the given URL as the desktop wallpaper for the given screen.
    static func set(_ url: URL, screen: NSScreen) throws {
        do {
            try NSWorkspace.shared.setDesktopImageURL(
                url,
                for: screen,
                options: [
                    .allowClipping: true,
                    .imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue,
                ]
            )
        } catch {
            Logger.wallpaper.error("Error setting wallpaper: \(error)")
            throw WallpaperError.failedToSetWallpaper(underlying: error)
        }
    }
}

// MARK: - Logger
private extension Logger {
    /// The logger to use for wallpaper management.
    static let wallpaper = Logger(category: "Wallpaper")
}

// MARK: - Helpers
private extension NSImage {
    /// The receiver's representation as PNG data.
    var pngData: Data? {
        guard
            let tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
