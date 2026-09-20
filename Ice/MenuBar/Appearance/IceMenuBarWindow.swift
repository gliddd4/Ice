//
//  IceMenuBarWindow.swift
//  Ice
//
//  Reconstructed from the compiled binary of the 2026-09-02 build.
//  Recovered API surface:
//    final class IceMenuBarWindow: NSWindow
//      init(contentRect:styleMask:backing:defer:)
//      func setup()
//      func suppressShadow()
//
//  `setup()` contains one closure over `NSAnimationContext`; `suppressShadow()`
//  contains two closures over `CALayer`. Exact closure shapes are inferred.
//

import Cocoa

/// A borderless, non-interactive window that sits behind the menu bar and hosts
/// a transparent backdrop view.
final class IceMenuBarWindow: NSWindow {
    /// Creates a menu bar window with the given content rectangle.
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        setup()
    }

    /// Configures the receiver for use as a menu bar backdrop window.
    func setup() {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            suppressShadow()
        }
    }

    /// Removes the shadow from the receiver and its content view's layers.
    func suppressShadow() {
        contentView?.wantsLayer = true

        // Clear the shadow on the content view's own layer.
        [contentView?.layer].forEach { layer in
            layer?.shadowOpacity = 0
            layer?.shadowRadius = 0
            layer?.shadowOffset = .zero
            layer?.shadowColor = NSColor.clear.cgColor
        }

        // Clear the shadow on each sublayer contributed by the visual effect view.
        contentView?.layer?.sublayers?.forEach { layer in
            layer.shadowOpacity = 0
            layer.shadowRadius = 0
            layer.shadowColor = NSColor.clear.cgColor
        }

        hasShadow = false
        invalidateShadow()
    }
}
