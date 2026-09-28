//
//  MenuBarWallpaper.swift
//  Ice
//
//  Reads the desktop wallpaper for a screen and maps it onto menu bar regions.
//
//  macOS lays a wallpaper out on the display itself - filling, fitting, centring or
//  stretching it, and painting a fill colour around the edges - so a window that
//  wants to show what belongs behind the menu bar has to reproduce that layout
//  rather than scale the image to its own bounds. Reading the wallpaper file also
//  avoids the Screen Recording permission that capturing the wallpaper window needs.
//

import AppKit

/// The wallpaper pixels that belong behind a given region of a screen, together
/// with the placement needed to draw them.
struct MenuBarWallpaperCrop {
    /// The cropped wallpaper.
    ///
    /// `nil` when the screen has no wallpaper image at all - a solid colour or a
    /// gradient desktop - in which case ``background`` is the whole region.
    let image: CGImage?

    /// Where the crop belongs inside the region, in the region's own pixel space,
    /// with a top-left origin.
    let destination: CGRect

    /// The full pixel size of the region the crop was made for.
    let pixelSize: CGSize
}

/// Reads the current wallpaper and maps it onto menu bar frames.
enum MenuBarWallpaper {
    /// How macOS has laid the wallpaper out on a screen.
    struct Layout {
        /// The rect the image occupies, in screen pixels with a top-left origin.
        let destination: CGRect
        /// The image's pixel size.
        let imageSize: CGSize
        /// The screen's pixel size.
        let screenSize: CGSize
        /// The screen's backing scale factor.
        let scaleFactor: CGFloat
    }

    /// A wallpaper image together with the file attributes it was read from.
    private struct CacheEntry {
        let url: URL
        let modified: Date
        let size: Int
        let image: CGImage
    }

    /// The defaults key holding the wallpaper that Ice replaced with a banded copy.
    private static let originalWallpaperDefaultsKey = "IceTransparentOriginalWallpaperURL"

    /// Cached images, keyed by display.
    private static var cache: [CGDirectDisplayID: CacheEntry] = [:]

    // MARK: - Source

    /// The wallpaper that Ice replaced with a copy of its own, persisted across
    /// launches so that a run that ends abruptly can still find it again.
    static var originalWallpaperURL: URL? {
        get {
            guard let url = UserDefaults.standard.url(forKey: originalWallpaperDefaultsKey) else {
                return nil
            }
            // User defaults stores a URL relative to the home directory when it can, and
            // hands back an unexpanded "~" path, which no file operation accepts. Reading
            // the wallpaper through it would silently fail, leaving Ice showing the
            // banded copy it was trying to get away from.
            return URL(fileURLWithPath: (url.path as NSString).expandingTildeInPath)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: originalWallpaperDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: originalWallpaperDefaultsKey)
            }
        }
    }

    /// Returns a Boolean value that indicates whether the given URL points at a
    /// wallpaper that Ice wrote.
    static func isManagedWallpaper(_ url: URL) -> Bool {
        let directory = url.deletingLastPathComponent().standardizedFileURL

        let managed = Wallpaper.applicationSupportDirectory()?.standardizedFileURL
        if managed == directory {
            return true
        }

        // Wallpapers written before Ice used the Wallpapers subdirectory sit directly
        // in the application support directory. Re-banding one of those would band an
        // image that is already banded, and would lose track of the wallpaper Ice
        // replaced in the first place.
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return false
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "Ice"
        return directory == base.appendingPathComponent(bundleID).standardizedFileURL
    }

    // MARK: - Reading the wallpaper

    /// The URL that the wallpaper for the given screen should be read from.
    ///
    /// Usually this is simply the screen's desktop picture. It is not when Ice is
    /// managing the wallpaper: Ice installs a copy carrying an opaque band across the
    /// menu bar area, and a view that has to show the bar as transparent needs the
    /// wallpaper Ice replaced, not the banded copy.
    static func sourceURL(for screen: NSScreen) -> URL? {
        guard let desktopPicture = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return nil
        }
        guard isManagedWallpaper(desktopPicture) else {
            return desktopPicture
        }
        guard
            let original = originalWallpaperURL,
            FileManager.default.fileExists(atPath: original.path)
        else {
            return desktopPicture
        }
        return original
    }

    /// Returns the wallpaper image currently installed for the given screen.
    ///
    /// The image is cached and only reread when the underlying file changes.
    static func image(for screen: NSScreen) -> CGImage? {
        let displayID = screen.displayID
        guard let url = sourceURL(for: screen) else {
            cache.removeValue(forKey: displayID)
            return nil
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0

        if
            let cached = cache[displayID],
            cached.url == url,
            cached.modified == modified,
            cached.size == size
        {
            return cached.image
        }

        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }

        cache[displayID] = CacheEntry(url: url, modified: modified, size: size, image: image)
        return image
    }

    /// Replicates the layout that macOS uses for a screen's wallpaper options.
    static func layout(for screen: NSScreen, imageSize: CGSize) -> Layout {
        let scaleFactor = screen.backingScaleFactor
        let screenSize = CGSize(
            width: screen.frame.width * scaleFactor,
            height: screen.frame.height * scaleFactor
        )

        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        let scaling = (options[.imageScaling] as? NSNumber)
            .flatMap { NSImageScaling(rawValue: $0.uintValue) }
            ?? .scaleProportionallyUpOrDown
        let allowClipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true

        let size: CGSize
        switch scaling {
        case .scaleAxesIndependently:
            // "Stretch to Fill Screen" - the image is distorted to the screen size.
            size = screenSize

        case .scaleNone:
            // "Center" - the image is drawn at its native pixel size.
            size = imageSize

        case .scaleProportionallyDown:
            // "Fit to Screen" - shrink to fit. macOS does not upscale in this mode
            // unless clipping is allowed.
            let fit = min(screenSize.width / imageSize.width, screenSize.height / imageSize.height)
            let scale = allowClipping ? fit : min(fit, 1)
            size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)

        default:
            // "Fill Screen" - scale up or down until the screen is fully covered.
            let fill = max(screenSize.width / imageSize.width, screenSize.height / imageSize.height)
            size = CGSize(width: imageSize.width * fill, height: imageSize.height * fill)
        }

        let destination = CGRect(
            x: (screenSize.width - size.width) / 2,
            y: (screenSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )

        return Layout(
            destination: destination,
            imageSize: imageSize,
            screenSize: screenSize,
            scaleFactor: scaleFactor
        )
    }

    // MARK: - Menu bar geometry

    /// The height of the menu bar on the given screen.
    ///
    /// Measured from the system's own menu bar window, because the gap between a
    /// screen's `frame` and its `visibleFrame` is not reliable: on a 1440x900 display
    /// it reports 25 points while the menu bar window is only 24 points tall.
    static func menuBarHeight(for screen: NSScreen) -> CGFloat {
        if let measured = screen.getMenuBarHeight(), measured > 0 {
            return measured
        }
        let inset = screen.frame.maxY - screen.visibleFrame.maxY
        if inset > 0 {
            return inset
        }
        return NSStatusBar.system.thickness
    }

    /// The frame of the menu bar on the given screen, in screen coordinates.
    static func menuBarRect(for screen: NSScreen) -> CGRect {
        let height = menuBarHeight(for: screen)
        return CGRect(
            x: screen.frame.minX,
            y: screen.frame.maxY - height,
            width: screen.frame.width,
            height: height
        )
    }

    // MARK: - Cropping

    /// Returns the wallpaper pixels that lie underneath `frame` on `screen`.
    ///
    /// `frame` is in screen coordinates (points).
    ///
    /// - Returns: `nil` when the screen is not usable at all, which is the case for a
    ///   stale `NSScreen` - one captured before a display change or a fullscreen
    ///   transition. Such a screen reports a backing scale factor of zero and gives
    ///   nothing back from `desktopImageURL(for:)`, which would otherwise collapse the
    ///   crop to nothing. Callers should treat `nil` as "draw nothing" rather than as
    ///   a reason to paint a placeholder colour.
    ///
    ///   When the screen is fine but no wallpaper image can be read - a solid colour
    ///   or gradient desktop - the result carries a `nil` image, and callers should
    ///   draw nothing: Ice never paints a region the wallpaper does not cover, because
    ///   anything it painted there would be a bar of its own making.
    static func crop(for screen: NSScreen, frame: CGRect) -> MenuBarWallpaperCrop? {
        let scaleFactor = screen.backingScaleFactor
        guard scaleFactor > 0, frame.width > 0, frame.height > 0 else {
            return nil
        }

        let pixelSize = CGSize(
            width: frame.width * scaleFactor,
            height: frame.height * scaleFactor
        )

        func flat() -> MenuBarWallpaperCrop {
            MenuBarWallpaperCrop(
                image: nil,
                destination: .zero,
                pixelSize: pixelSize
            )
        }

        guard let image = image(for: screen) else {
            return flat()
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        let layout = layout(for: screen, imageSize: imageSize)

        // The frame in screen pixels, with a top-left origin.
        let region = CGRect(
            x: (frame.minX - screen.frame.minX) * scaleFactor,
            y: (screen.frame.maxY - frame.maxY) * scaleFactor,
            width: pixelSize.width,
            height: pixelSize.height
        )

        // Map the region from screen pixels into the image's own pixel space.
        let scaleX = layout.destination.width / imageSize.width
        let scaleY = layout.destination.height / imageSize.height
        guard scaleX > 0, scaleY > 0 else {
            return flat()
        }

        let source = CGRect(
            x: (region.minX - layout.destination.minX) / scaleX,
            y: (region.minY - layout.destination.minY) / scaleY,
            width: region.width / scaleX,
            height: region.height / scaleY
        )

        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let clipped = source.intersection(imageBounds)
        // `cropping(to:)` returns `nil` when the rect is not fully inside the image,
        // which can happen for a region flush against an edge once the rect has been
        // rounded out to whole pixels. Clamping it back to the image keeps the crop
        // rather than losing it: drawing nothing at all is the last resort, because
        // anything Ice paints where the wallpaper is missing is a bar of its own.
        let cropRect = clipped.integral.intersection(imageBounds)
        guard !cropRect.isEmpty, let cropped = image.cropping(to: cropRect) else {
            return flat()
        }

        // Where the crop lands inside the region, in the region's pixel space.
        let destination = CGRect(
            x: (clipped.minX - source.minX) * scaleX,
            y: (clipped.minY - source.minY) * scaleY,
            width: CGFloat(cropped.width) * scaleX,
            height: CGFloat(cropped.height) * scaleY
        )

        return MenuBarWallpaperCrop(
            image: cropped,
            destination: destination,
            pixelSize: pixelSize
        )
    }

    /// Returns a copy of `image` with an opaque band painted across the area that the
    /// menu bar covers once the image has been laid out on `screen`.
    ///
    /// The band keeps the desktop from contributing anything of its own behind a
    /// transparent menu bar, so that whatever Ice paints over the bar is the only
    /// thing visible there.
    static func bandedImage(_ image: CGImage, for screen: NSScreen) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let layout = layout(for: screen, imageSize: imageSize)
        guard layout.destination.height > 0, imageSize.height > 0 else {
            return nil
        }

        // How many rows of the image the menu bar covers, which depends on how macOS
        // scaled the image to fit the display.
        let deviceRows = menuBarHeight(for: screen) * layout.scaleFactor
        let rows = Int((deviceRows * imageSize.height / layout.destination.height).rounded())
        guard rows > 0, rows < image.height else {
            return nil
        }

        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(
            CGRect(
                x: 0,
                y: image.height - rows,
                width: image.width,
                height: rows
            )
        )
        return context.makeImage()
    }
}
