//
//  MenuBarTransparentBackdrop.swift
//  Ice
//
//  Makes the menu bar transparent without hiding what the menu bar draws.
//
//  The bar has a backdrop of its own, drawn by the system above anything an app can
//  place on the desktop, so simply painting the wallpaper over the bar covers the bar's
//  menus and status items - and cutting holes for them shows the backdrop through the
//  holes. Both are visible as bars of their own.
//
//  The receiver filters the backdrop instead of replacing it. A backdrop layer samples
//  what the system draws behind the window - the bar's surface and its items - and a
//  filter chain flattens that surface to black while leaving the items alone. The
//  wallpaper is then composited over the top with a blend that a black surface has no
//  effect on, so the wallpaper shows through everywhere the bar draws its own surface,
//  and the bar's items stay exactly as the system drew them.
//
//  The wallpaper comes from the original that Ice replaced with a banded copy, so the
//  black band the desktop carries is never what the bar shows.
//

import AppKit

/// A view that shows the wallpaper behind a transparent menu bar, with the menu bar's
/// own content still visible over it.
final class MenuBarTransparentBackdropView: NSVisualEffectView {
    /// The types of the Core Animation filters the receiver is built from.
    private enum FilterType {
        /// Turns the backdrop's surface black.
        static let brightness = "colorBrightness"
        /// Leaves the backdrop's contrast alone.
        static let contrast = "colorContrast"
        /// Turns a light backdrop dark, so that light mode behaves like dark mode.
        static let invert = "colorInvert"
        /// Undoes the hue shift that the invert filter introduces.
        static let hueRotate = "colorHueRotate"
        /// Leaves whatever is brighter than the wallpaper showing, which keeps the
        /// backdrop's items visible.
        static let screenBlend = "screenBlendMode"
        /// Darkens the items instead, for light mode.
        static let multiplyBlend = "multiplyBlendMode"
    }

    /// The screen whose menu bar the receiver backs.
    let screen: NSScreen

    /// The layer that samples what the system draws behind the receiver.
    private var backdrop: CABackdropLayer?

    /// The layer that holds the backdrop and the wallpaper, so that the wallpaper is
    /// composited against the backdrop alone.
    private var container: CALayer?

    /// The layer that carries the wallpaper and the blend it is composited with.
    private var wallpaperContainer: CALayer?

    /// The layer that displays the wallpaper behind the bar.
    private var wallpaper: CALayer?

    /// The filter that flattens the backdrop's surface to black.
    private var brightnessFilter: CAFilter?

    /// The filter that leaves the backdrop's contrast alone.
    private var contrastFilter: CAFilter?

    /// The filter that turns a light backdrop dark.
    private var invertFilter: CAFilter?

    /// The filter that undoes the hue shift introduced by ``invertFilter``.
    private var hueRotateFilter: CAFilter?

    /// The timer used to poll for wallpaper changes.
    ///
    /// The wallpaper can change without any notification that can be relied on, so poll.
    /// Reads are cached by the wallpaper file's modification date, so this stays cheap.
    private var timer: Timer?

    /// Observer for workspace space changes.
    private var spaceChangeObserver: NSObjectProtocol?

    /// Observer for screen wake notifications.
    private var screenDidWakeObserver: NSObjectProtocol?

    /// Creates a backdrop view for the given screen.
    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: .zero)
        commonInit()
    }

    override init(frame frameRect: NSRect) {
        self.screen = NSScreen.main ?? NSScreen.screens[0]
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        self.screen = NSScreen.main ?? NSScreen.screens[0]
        super.init(coder: coder)
        commonInit()
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Setup

    /// Performs the setup shared by every initializer.
    private func commonInit() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        state = .active
        material = .menu
        blendingMode = .behindWindow
        // Tell the visual effect view to draw no material of its own. Its backdrop is
        // built below instead, as the carrier for the filters.
        setValue(true, forKey: "clear")

        buildLayers()
        applyFilters()

        let center = NotificationCenter.default

        spaceChangeObserver = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshWallpaper()
            }
        }

        screenDidWakeObserver = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshWallpaper()
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshWallpaper()
            }
        }

        refreshWallpaper()
    }

    /// Builds the layer tree: a backdrop that samples what the system draws behind the
    /// receiver, and a wallpaper that is composited against it.
    private func buildLayers() {
        guard let layer else {
            return
        }

        let containerLayer = CALayer()
        containerLayer.masksToBounds = true
        containerLayer.allowsEdgeAntialiasing = false
        layer.addSublayer(containerLayer)
        container = containerLayer

        let backdropLayer = CABackdropLayer()
        backdropLayer.masksToBounds = true
        backdropLayer.allowsGroupOpacity = true
        backdropLayer.allowsEdgeAntialiasing = false
        // The backdrop has to be sampled and filtered by the window server: it is the
        // system's own drawing behind this window that is being filtered, and only the
        // window server has it.
        backdropLayer.setValue(true, forKey: "windowServerAware")
        backdropLayer.setValue(1, forKey: "scale")
        backdropLayer.setValue(0.1, forKey: "bleedAmount")
        containerLayer.addSublayer(backdropLayer)
        backdrop = backdropLayer

        let wallpaperContainerLayer = CALayer()
        wallpaperContainerLayer.masksToBounds = true
        containerLayer.addSublayer(wallpaperContainerLayer)
        wallpaperContainer = wallpaperContainerLayer

        let wallpaperLayer = CALayer()
        wallpaperLayer.contentsGravity = .resize
        wallpaperContainerLayer.addSublayer(wallpaperLayer)
        wallpaper = wallpaperLayer

        brightnessFilter = CAFilter(type: FilterType.brightness)
        contrastFilter = CAFilter(type: FilterType.contrast)
        invertFilter = CAFilter(type: FilterType.invert)
        hueRotateFilter = CAFilter(type: FilterType.hueRotate)
        hueRotateFilter?.setValue(Double.pi, forKey: "inputAngle")

        backdropLayer.filters = [
            brightnessFilter,
            contrastFilter,
            invertFilter,
            hueRotateFilter,
        ].compactMap { $0 }
    }

    // MARK: - Filters

    /// Applies the filters and the blend that turn the bar's backdrop into the wallpaper.
    ///
    /// The surface the bar draws is already black wherever the desktop carries the band
    /// Ice installed, which is what the brightness and contrast filters keep. Screening
    /// the wallpaper over a black surface shows the wallpaper, and screening it over the
    /// bar's bright items leaves them bright, so the items stay visible.
    ///
    /// A light backdrop needs the same treatment the other way around: it is inverted
    /// (and rotated back to the right hue) to make it dark, and the wallpaper is
    /// multiplied over it, which leaves the items dark instead of the bar.
    private func applyFilters() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        brightnessFilter?.setValue(0.0, forKey: "inputAmount")
        contrastFilter?.setValue(1.0, forKey: "inputAmount")
        invertFilter?.setValue(!isDark, forKey: "enabled")
        hueRotateFilter?.setValue(!isDark, forKey: "enabled")

        wallpaperContainer?.compositingFilter = CAFilter(
            type: isDark ? FilterType.screenBlend : FilterType.multiplyBlend
        )
    }

    // MARK: - Wallpaper

    /// Installs the current wallpaper behind the bar.
    ///
    /// Idempotent, so it is safe to call on a timer. That is what lets the backdrop
    /// recover by itself after a wallpaper or display change.
    func refreshWallpaper() {
        // A screen mid display transition reports a backing scale factor of zero and
        // would collapse the crop to nothing.
        guard screen.backingScaleFactor > 0 else {
            return
        }

        let crop = MenuBarWallpaper.crop(
            for: screen,
            frame: MenuBarWallpaper.menuBarRect(for: screen)
        )

        // A `nil` image means a solid colour or gradient desktop, and there is no
        // wallpaper to show, so the bar is left as the system drew it.
        wallpaper?.contents = crop?.image
        wallpaper?.contentsScale = screen.backingScaleFactor
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let bounds = layer?.bounds ?? .zero
        container?.frame = bounds
        backdrop?.frame = bounds
        wallpaperContainer?.frame = bounds
        wallpaper?.frame = bounds
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshWallpaper()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFilters()
    }
}
