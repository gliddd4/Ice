//
//  OverlayEffect.swift
//  Ice
//
//  Reconstructed from the compiled binary of the 2026-09-02 build.
//  Recovered API surface:
//    struct OverlayEffect
//      let tintColor: () -> NSColor
//      init(_ tintColor: @autoclosure () -> NSColor)
//      static let clear / darkShadow / lightShadow
//

import Cocoa

/// An effect that is composited as a tint layer over the menu bar backdrop.
///
/// The tint color is stored as an autoclosure so that it can be resolved lazily,
/// which keeps dynamic (appearance-dependent) colors working.
struct OverlayEffect {
    /// A closure that resolves the tint color for the overlay.
    let tintColor: () -> NSColor

    /// Creates an effect with the given tint color.
    ///
    /// - Parameter tintColor: An autoclosure that resolves the tint color.
    init(_ tintColor: @autoclosure @escaping () -> NSColor) {
        self.tintColor = tintColor
    }

    /// An effect that applies no tint at all.
    static var clear = OverlayEffect(.clear)

    /// An effect that applies a dark shadow tint.
    ///
    /// Alpha recovered from the binary's literal pool.
    static var darkShadow = OverlayEffect(NSColor.black.withAlphaComponent(0.28))

    /// An effect that applies a light shadow tint.
    ///
    /// Alpha recovered from the binary's literal pool.
    static var lightShadow = OverlayEffect(NSColor.white.withAlphaComponent(0.35))
}
