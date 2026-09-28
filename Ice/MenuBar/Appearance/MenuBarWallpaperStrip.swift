//
//  MenuBarWallpaperStrip.swift
//  Ice
//
//  A hairline strip pinned to the bottom edge of the menu bar that redraws the
//  wallpaper beneath it, hiding the shadow that the system draws under the bar.
//
//  Ported from the WallpaperStrip app so that the strip ships with Ice instead of
//  running as a separate process.
//

import AppKit

/// A borderless window that sits over the shadow underneath the menu bar.
final class MenuBarWallpaperStripWindow: NSWindow {
    /// The strip's height, in points.
    ///
    /// The shadow under the menu bar is only a couple of points tall, so the strip
    /// only needs to be as tall as the shadow it covers.
    static let height: CGFloat = 2

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        // High enough to sit above the menu bar and Ice's own windows, so that the
        // shadow the strip exists to hide cannot be drawn on top of it, but low enough
        // to stay underneath pop-up menus, notifications and the rest of the system's
        // overlays.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        // The menu bar, and therefore its shadow, is not on screen in fullscreen, so
        // there is nothing for the strip to do there.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone, .ignoresCycle]
    }
}

/// Draws the wallpaper that belongs underneath the strip's current position.
final class MenuBarWallpaperStripView: NSView {
    /// The crop to draw, or `nil` when there is nothing to show.
    var crop: MenuBarWallpaperCrop? {
        didSet {
            needsDisplay = true
        }
    }

    override var isOpaque: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        // Nothing but wallpaper. The strip is never filled with a colour of its own:
        // a `nil` image means a solid colour or gradient desktop, and there is no crop
        // to show, so the strip stays out of the way rather than painting a bar.
        guard
            let context = NSGraphicsContext.current?.cgContext,
            let crop,
            let image = crop.image
        else {
            return
        }

        // `destination` is in the crop's pixel space with a top-left origin. The view's
        // own coordinate space is bottom-left in points, so convert rather than
        // flipping the context - that keeps the image upright.
        let scale = window?.backingScaleFactor ?? 2
        let destination = crop.destination
        let rect = CGRect(
            x: destination.minX / scale,
            y: (crop.pixelSize.height - destination.maxY) / scale,
            width: destination.width / scale,
            height: destination.height / scale
        )

        context.saveGState()
        context.draw(image, in: rect)
        context.restoreGState()
    }
}

/// Owns the strip window for a single screen and keeps its contents in sync with the
/// wallpaper.
final class MenuBarWallpaperStripController {
    /// The screen the strip belongs to.
    let screen: NSScreen

    private let window: MenuBarWallpaperStripWindow
    private let stripView = MenuBarWallpaperStripView()
    private var timer: Timer?

    init(screen: NSScreen) {
        self.screen = screen
        self.window = MenuBarWallpaperStripWindow(
            frame: CGRect(
                x: screen.frame.minX,
                y: screen.frame.maxY - MenuBarWallpaperStripWindow.height,
                width: screen.frame.width,
                height: MenuBarWallpaperStripWindow.height
            )
        )

        stripView.frame = CGRect(origin: .zero, size: window.frame.size)
        stripView.autoresizingMask = [.width, .height]
        window.contentView = stripView

        apply()

        // The wallpaper can change without any notification that can be relied on, so
        // poll. Reads are cached by the wallpaper file's modification date, so this
        // stays cheap.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.apply()
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    /// Positions the strip and recomputes its wallpaper crop.
    ///
    /// Idempotent, so it is safe to call on a timer. That is what lets the strip
    /// recover by itself after a wallpaper or display change.
    func apply() {
        // A screen mid display transition reports a backing scale factor of zero and
        // would collapse the crop to nothing, so leave the strip where it is.
        guard screen.backingScaleFactor > 0 else {
            return
        }

        let frame = CGRect(
            x: screen.frame.minX,
            y: MenuBarWallpaper.menuBarRect(for: screen).minY - MenuBarWallpaperStripWindow.height,
            width: screen.frame.width,
            height: MenuBarWallpaperStripWindow.height
        )

        if window.frame != frame {
            window.setFrame(frame, display: true)
        }

        stripView.crop = MenuBarWallpaper.crop(for: screen, frame: frame)

        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    /// Closes the strip's window.
    func close() {
        window.orderOut(nil)
        window.close()
    }
}
