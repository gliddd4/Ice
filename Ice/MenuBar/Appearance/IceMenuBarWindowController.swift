//
//  IceMenuBarWindowController.swift
//  Ice
//
//  Reconstructed from the compiled binary of the 2026-09-02 build.
//  Recovered API surface:
//    final class IceMenuBarWindowController: NSWindowController
//      init(window: IceMenuBarWindow, screen: NSScreen)
//      override init(window: NSWindow?)
//      required init?(coder: NSCoder)
//

import Cocoa

/// Owns an ``IceMenuBarWindow`` and keeps it sized to the menu bar of a screen.
final class IceMenuBarWindowController: NSWindowController {
    /// The screen whose menu bar the receiver's window covers.
    let screen: NSScreen

    /// Creates a controller that manages the given window for the given screen.
    ///
    /// - Parameters:
    ///   - window: The menu bar window to manage.
    ///   - screen: The screen whose menu bar the window covers.
    init(window: IceMenuBarWindow, screen: NSScreen) {
        self.screen = screen
        super.init(window: window)
    }

    override init(window: NSWindow?) {
        self.screen = NSScreen.main ?? NSScreen.screens[0]
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        self.screen = NSScreen.main ?? NSScreen.screens[0]
        super.init(coder: coder)
    }

    /// The menu bar window managed by the receiver.
    var menuBarWindow: IceMenuBarWindow? {
        window as? IceMenuBarWindow
    }

    /// Sizes the receiver's window to cover the full frame of ``screen``.
    ///
    /// The window spans the whole screen so that the backdrop view can position
    /// the wallpaper layer without clamping; the menu bar strip is the only part
    /// that ends up visible.
    func updateWindowFrame() {
        guard let window else {
            return
        }
        window.setFrame(screen.frame, display: false)
    }
}
