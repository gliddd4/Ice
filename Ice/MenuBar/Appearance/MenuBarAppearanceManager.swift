//
//  MenuBarAppearanceManager.swift
//  Ice
//

import Cocoa
import Combine

/// A manager for the appearance of the menu bar.
@MainActor
final class MenuBarAppearanceManager: ObservableObject {
    /// The current menu bar appearance configuration.
    @Published var configuration: MenuBarAppearanceConfigurationV2 = .defaultConfiguration

    /// The currently previewed partial configuration.
    @Published var previewConfiguration: MenuBarAppearancePartialConfiguration?

    /// The shared app state.
    private weak var appState: AppState?

    /// Encoder for UserDefaults values.
    private let encoder = JSONEncoder()

    /// Decoder for UserDefaults values.
    private let decoder = JSONDecoder()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The currently managed menu bar overlay panels.
    private(set) var overlayPanels = Set<MenuBarOverlayPanel>()

    /// The currently managed transparent menu bar windows.
    ///
    /// Reconstructed from the compiled binary of the 2026-09-02 build.
    private var transparentWindowControllers: [IceMenuBarWindowController] = []

    /// The amount to inset the menu bar if called for by the configuration.
    let menuBarInsetAmount: CGFloat = 5

    /// Creates a manager with the given app state.
    init(appState: AppState) {
        self.appState = appState
    }

    /// Performs initial setup of the manager.
    func performSetup() {
        loadInitialState()
        configureCancellables()
    }

    /// Loads the initial values for the configuration.
    private func loadInitialState() {
        do {
            if let data = Defaults.data(forKey: .menuBarAppearanceConfigurationV2) {
                configuration = try decoder.decode(MenuBarAppearanceConfigurationV2.self, from: data)
            }
        } catch {
            Logger.appearanceManager.error("Error decoding configuration: \(error)")
        }
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .debounce(for: 0.1, scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else {
                    return
                }
                while let panel = overlayPanels.popFirst() {
                    panel.orderOut(self)
                }
                if Set(overlayPanels.map { $0.owningScreen }) != Set(NSScreen.screens) {
                    configureOverlayPanels(with: configuration)
                }
                updateTransparentWindows(for: configuration)
            }
            .store(in: &c)

        $configuration
            .encode(encoder: encoder)
            .receive(on: DispatchQueue.main)
            .sink { completion in
                if case .failure(let error) = completion {
                    Logger.appearanceManager.error("Error encoding configuration: \(error)")
                }
            } receiveValue: { data in
                Defaults.set(data, forKey: .menuBarAppearanceConfigurationV2)
            }
            .store(in: &c)

        $configuration
            .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] configuration in
                guard let self else {
                    return
                }
                // The overlay panels may not have been configured yet. Since some of the
                // properties on the manager might call for them, try to configure now.
                if overlayPanels.isEmpty {
                    configureOverlayPanels(with: configuration)
                }
                updateTransparentWindows(for: configuration)
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a Boolean value that indicates whether a set of overlay panels
    /// is needed for the given configuration.
    private func needsOverlayPanels(for configuration: MenuBarAppearanceConfigurationV2) -> Bool {
        let current = configuration.current
        if current.hasShadow {
            return true
        }
        if current.hasBorder {
            return true
        }
        if configuration.shapeKind != .none {
            return true
        }
        if current.tintKind != .none {
            return true
        }
        return false
    }

    /// Configures the manager's overlay panels, if required by the given configuration.
    private func configureOverlayPanels(with configuration: MenuBarAppearanceConfigurationV2) {
        guard
            let appState,
            needsOverlayPanels(for: configuration)
        else {
            while let panel = overlayPanels.popFirst() {
                panel.close()
            }
            return
        }

        var overlayPanels = Set<MenuBarOverlayPanel>()
        for screen in NSScreen.screens {
            let panel = MenuBarOverlayPanel(appState: appState, owningScreen: screen)
            overlayPanels.insert(panel)
            panel.needsShow = true
        }

        self.overlayPanels = overlayPanels
    }

    /// Configures the manager's transparent menu bar windows, if required by the
    /// given configuration.
    ///
    /// Reconstructed from the compiled binary of the 2026-09-02 build. The signature
    /// is recovered exactly; the body is inferred.
    private func updateTransparentWindows(for configuration: MenuBarAppearanceConfigurationV2) {
        // Tear down any windows that are no longer called for.
        guard configuration.shapeKind == .transparent else {
            tearDownTransparentWindows()
            return
        }

        // Nothing to do if the windows already cover exactly the current screens.
        if Set(transparentWindowControllers.map(\.screen)) == Set(NSScreen.screens) {
            return
        }

        tearDownTransparentWindows()

        var controllers: [IceMenuBarWindowController] = []
        for screen in NSScreen.screens {
            let window = IceMenuBarWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.contentView = MenuBarTransparentBackdropView(screen: screen)

            let controller = IceMenuBarWindowController(window: window, screen: screen)
            controller.updateWindowFrame()
            controller.showWindow(self)
            controllers.append(controller)
        }

        transparentWindowControllers = controllers
    }

    /// Closes the manager's transparent menu bar windows and restores any
    /// wallpapers they modified.
    private func tearDownTransparentWindows() {
        for controller in transparentWindowControllers {
            if let backdrop = controller.window?.contentView as? MenuBarTransparentBackdropView {
                backdrop.restoreOriginalWallpaper()
            }
            controller.close()
        }
        transparentWindowControllers = []
    }

    /// Sets the value of ``MenuBarOverlayPanel/isDraggingMenuBarItem`` for each
    /// of the manager's overlay panels.
    func setIsDraggingMenuBarItem(_ isDragging: Bool) {
        for panel in overlayPanels {
            panel.isDraggingMenuBarItem = isDragging
        }
    }
}

// MARK: MenuBarAppearanceManager: BindingExposable
extension MenuBarAppearanceManager: BindingExposable { }

// MARK: - Transparent menu bar backdrop

/// A visual effect view that draws the desktop wallpaper behind a transparent
/// menu bar.
///
/// The system normally composites the menu bar over the desktop with its own blur
/// and tint. This view neutralises that backdrop by installing a modified copy of
/// the wallpaper that carries an opaque band across the menu bar area, then draws
/// the real wallpaper content itself so the bar appears fully transparent.
final class MenuBarTransparentBackdropView: NSVisualEffectView {
    // MARK: - Stored properties

    /// Storage for the receiver's visual effect state.
    private var _state: NSVisualEffectView.State = .active {
        didSet {
            super.state = _state
            refreshWallpaper()
        }
    }

    /// The backdrop layer that the system uses to composite the effect.
    private var backdrop: CABackdropLayer?

    /// The layer that hosts every sublayer owned by the receiver.
    private var container: CALayer?

    /// The gradient layer drawn beneath the wallpaper.
    private var gradient: CAGradientLayer?

    /// The tint layer.
    private var tint: CALayer?

    /// The layer that displays the wallpaper image.
    private var wallpaper: CALayer?

    /// The layer that clips ``wallpaper``.
    private var wallpaperContainer: CALayer?

    /// The overlay effect applied on top of the wallpaper.
    private var effect: OverlayEffect = .clear {
        didSet {
            applyEffect()
        }
    }

    /// The path of the wallpaper that is currently displayed.
    private var currentWallpaperPath: URL?

    /// The path of the modified wallpaper that the receiver installed.
    private var modifiedWallpaperURL: URL?

    /// The path of the wallpaper that was installed before the receiver modified it.
    private var originalWallpaperURL: URL?

    /// The defaults key used to persist ``originalWallpaperURL`` across launches.
    private static let originalWallpaperDefaultsKey = "IceTransparentOriginalWallpaperURL"

    /// The screen whose menu bar the receiver backs.
    private let screen: NSScreen

    /// The timer used to poll for wallpaper changes.
    private var timer: Timer?

    /// Observer for workspace space changes.
    private var spaceChangeObserver: NSObjectProtocol?

    /// Observer for screen wake notifications.
    private var screenDidWakeObserver: NSObjectProtocol?

    /// Observer for application termination.
    private var terminationObserver: NSObjectProtocol?

    // MARK: - Init

    /// Creates a backdrop view for the given screen.
    init(screen: NSScreen) {
        self.screen = screen
        super.init(frame: screen.frame)
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

    /// Performs the setup shared by every initializer.
    private func commonInit() {
        wantsLayer = true
        state = .active
        material = .menu
        blendingMode = .behindWindow

        // Restore any wallpaper that a previous run left modified.
        if let stored = UserDefaults.standard.url(forKey: Self.originalWallpaperDefaultsKey) {
            originalWallpaperURL = stored
        }

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

        terminationObserver = center.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.restoreOriginalWallpaper()
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshWallpaper()
            }
        }

        refreshWallpaper()
    }

    // MARK: - Overridden properties

    override var material: NSVisualEffectView.Material {
        didSet {
            refreshWallpaper()
        }
    }

    override var blendingMode: NSVisualEffectView.BlendingMode {
        didSet {
            refreshWallpaper()
        }
    }

    override var state: NSVisualEffectView.State {
        get {
            _state
        }
        set {
            _state = newValue
        }
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let bounds = bounds

        container?.frame = bounds
        wallpaperContainer?.frame = bounds
        wallpaper?.frame = bounds
        gradient?.frame = bounds
        tint?.frame = bounds

        applyEffect()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshWallpaper()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyEffect()
    }

    // MARK: - Geometry

    /// The height of the menu bar on ``screen``.
    private var menuBarHeight: CGFloat {
        max(screen.frame.maxY - screen.visibleFrame.maxY, 0)
    }

    /// The height of the portion of the menu bar that is currently visible.
    private var visibleMenuBarHeight: CGFloat {
        let options = NSApplication.shared.presentationOptions
        if options.contains(.autoHideMenuBar) || options.contains(.hideMenuBar) {
            return 0
        }
        return menuBarHeight
    }

    /// The height of the overlay that the receiver draws.
    private var overlayHeight: CGFloat {
        menuBarHeight
    }

    /// The height of the opaque band applied to the managed wallpaper.
    private var blackBandHeight: CGFloat {
        menuBarHeight
    }

    /// The height of the wallpaper strip that the receiver draws.
    private var stripHeight: CGFloat {
        visibleMenuBarHeight
    }

    /// A Boolean value that indicates whether the receiver must fall back to the
    /// system's own menu bar appearance.
    private var useFallback: Bool {
        installedWallpaperImage() == nil
    }

    // MARK: - Wallpaper capture

    /// Returns the window ID of the desktop wallpaper owned by the Dock.
    private func getCurrentWallpaperWindowID() -> UInt32? {
        guard
            let windowList = CGWindowListCopyWindowInfo(
                [.optionAll],
                kCGNullWindowID
            ) as? [[String: Any]]
        else {
            return nil
        }

        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))

        for info in windowList {
            guard
                let owner = info[kCGWindowOwnerName as String] as? String,
                owner == "Dock",
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == desktopLevel || layer == iconLevel,
                let number = info[kCGWindowNumber as String] as? NSNumber
            else {
                continue
            }
            return number.uint32Value
        }

        return nil
    }

    /// Captures the given window as an image.
    private func getWallpaperScreenshot(cgWindowID: UInt32) -> CGImage? {
        let windowIDs = [cgWindowID] as CFArray
        return CGImage(
            windowListFromArrayScreenBounds: .null,
            windowArray: windowIDs,
            imageOption: .bestResolution
        )
    }

    /// Captures the desktop wallpaper for ``screen``.
    private func captureWallpaperScreen() -> CGImage? {
        if let windowID = getCurrentWallpaperWindowID() {
            return getWallpaperScreenshot(cgWindowID: windowID)
        }
        return nil
    }

    /// Returns the wallpaper image currently installed for ``screen``.
    private func installedWallpaperImage() -> CGImage? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return nil
        }
        guard let image = NSImage(contentsOf: url) else {
            return nil
        }
        var rect = NSRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Returns a Boolean value that indicates whether the given URL points at a
    /// wallpaper written by ``Wallpaper``.
    private func isManagedWallpaper(_ url: URL) -> Bool {
        guard let directory = Wallpaper.applicationSupportDirectory() else {
            return false
        }
        return url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
    }

    /// Returns a Boolean value that indicates whether the given image already
    /// carries the opaque band applied by ``addBlackRectangleToWallpaperOverMenuBarArea(image:)``.
    private func hasManagedBand(_ image: CGImage) -> Bool {
        guard
            let data = image.dataProvider?.data,
            let pointer = CFDataGetBytePtr(data)
        else {
            return false
        }

        let length = CFDataGetLength(data)
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        let bytesPerRow = image.bytesPerRow

        // Sample the middle of the band that we would have written.
        let scale = CGFloat(image.height) / max(bounds.height, 1)
        let bandHeight = Int((blackBandHeight * scale).rounded())
        guard bandHeight > 1, bandHeight <= image.height else {
            return false
        }
        let y = min(bandHeight / 2, image.height - 1)

        var samples: [Double] = []
        let step = max(image.width / 32, 1)
        for x in stride(from: 0, to: image.width, by: step) {
            let offset = y * bytesPerRow + x * bytesPerPixel
            guard offset + 2 < length else {
                continue
            }
            let red = Double(pointer[offset])
            let green = Double(pointer[offset + 1])
            let blue = Double(pointer[offset + 2])
            samples.append((red + green + blue) / 3)
        }

        guard !samples.isEmpty else {
            return false
        }
        return samples.allSatisfy { $0 < 8 }
    }

    /// Returns a Boolean value that indicates whether two images have identical
    /// dimensions and pixel data.
    private func imagesEqual(_ lhs: CGImage, _ rhs: CGImage) -> Bool {
        guard lhs.width == rhs.width, lhs.height == rhs.height else {
            return false
        }
        guard
            let left = lhs.dataProvider?.data,
            let right = rhs.dataProvider?.data
        else {
            return false
        }
        return CFEqual(left, right)
    }

    // MARK: - Wallpaper modification

    /// Returns a copy of the image at the given path with the top
    /// ``blackBandHeight`` points removed.
    func cropWallpaperBelowMenuBarArea(imagePath: URL) -> NSImage? {
        guard
            let image = NSImage(contentsOf: imagePath),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            return nil
        }

        let scale = CGFloat(cgImage.height) / max(image.size.height, 1)
        let cropHeight = (blackBandHeight * scale).rounded()
        guard cropHeight > 0, cropHeight < CGFloat(cgImage.height) else {
            return nil
        }

        let rect = CGRect(
            x: 0,
            y: cropHeight,
            width: CGFloat(cgImage.width),
            height: CGFloat(cgImage.height) - cropHeight
        )
        guard let cropped = cgImage.cropping(to: rect) else {
            return nil
        }
        return NSImage(
            cgImage: cropped,
            size: NSSize(width: cropped.width, height: cropped.height)
        )
    }

    /// Returns a copy of the given image with an opaque rectangle drawn over the
    /// menu bar area.
    func addBlackRectangleToWallpaperOverMenuBarArea(image: NSImage) -> NSImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else {
            return nil
        }

        let result = NSImage(size: size)
        result.lockFocus()
        defer { result.unlockFocus() }

        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )

        NSColor.black.setFill()
        NSRect(
            x: 0,
            y: size.height - blackBandHeight,
            width: size.width,
            height: blackBandHeight
        ).fill()

        return result
    }

    /// Returns a copy of the image at the given path with an opaque rectangle
    /// drawn over the menu bar area.
    func addBlackRectangleToWallpaperOverMenuBarArea(imagePath: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: imagePath) else {
            return nil
        }
        return addBlackRectangleToWallpaperOverMenuBarArea(image: image)
    }

    /// Modifies the given image and installs it as the desktop wallpaper for
    /// ``screen``, remembering the wallpaper it replaced.
    func modifyImageAndSetAsWallpaper(image: CGImage) {
        let source = NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )

        guard
            let modified = addBlackRectangleToWallpaperOverMenuBarArea(image: source),
            let url = Wallpaper.saveWallpaper(modified)
        else {
            Logger.transparentMenuBar.error("Unable to build modified wallpaper.")
            return
        }

        rememberOriginalWallpaper()

        do {
            try Wallpaper.set(url, screen: screen)
        } catch {
            Logger.transparentMenuBar.error("Error while setting wallpaper: \(error)")
            return
        }

        modifiedWallpaperURL = url
        currentWallpaperPath = url
        updateWallpaperLayer(with: image)
    }

    /// Loads the image at the given path, modifies it, and installs it as the
    /// desktop wallpaper for ``screen``.
    func modifyImageAndSetAsWallpaper(path: URL) {
        guard
            let image = NSImage(contentsOf: path),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else {
            Logger.transparentMenuBar.error("Error while obtaining the wallpaper image.")
            return
        }
        modifyImageAndSetAsWallpaper(image: cgImage)
    }

    /// Records the wallpaper that is currently installed so that it can be put
    /// back by ``restoreOriginalWallpaper()``.
    private func rememberOriginalWallpaper() {
        guard originalWallpaperURL == nil else {
            return
        }
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return
        }
        if isManagedWallpaper(url) {
            return
        }
        originalWallpaperURL = url
        UserDefaults.standard.set(url, forKey: Self.originalWallpaperDefaultsKey)
    }

    /// Restores the wallpaper that was installed before the receiver modified it.
    func restoreOriginalWallpaper() {
        defer {
            originalWallpaperURL = nil
            modifiedWallpaperURL = nil
            currentWallpaperPath = nil
            UserDefaults.standard.removeObject(forKey: Self.originalWallpaperDefaultsKey)
        }

        guard let url = originalWallpaperURL
            ?? UserDefaults.standard.url(forKey: Self.originalWallpaperDefaultsKey)
        else {
            return
        }

        do {
            try Wallpaper.set(url, screen: screen)
        } catch {
            Logger.transparentMenuBar.error("Error while setting wallpaper: \(error)")
        }
    }

    // MARK: - Refresh

    /// Re-captures the wallpaper and reinstalls the modified copy if required.
    private func refreshWallpaper() {
        guard !useFallback else {
            return
        }

        guard let captured = captureWallpaperScreen() else {
            return
        }

        // Already carrying our band — make sure the layer is up to date and stop.
        if hasManagedBand(captured) {
            updateWallpaperLayer(with: captured)
            return
        }

        // The wallpaper changed underneath us; re-apply the modification.
        modifyImageAndSetAsWallpaper(image: captured)
    }

    // MARK: - Layers

    /// Installs the given image into the wallpaper layer.
    private func updateWallpaperLayer(with image: CGImage) {
        if wallpaper == nil {
            let containerLayer = CALayer()
            containerLayer.masksToBounds = true
            layer?.addSublayer(containerLayer)
            wallpaperContainer = containerLayer

            let gradientLayer = CAGradientLayer()
            gradientLayer.colors = [
                NSColor.clear.cgColor,
                NSColor.black.withAlphaComponent(0.2).cgColor,
            ]
            containerLayer.addSublayer(gradientLayer)
            gradient = gradientLayer

            let wallpaperLayer = CALayer()
            wallpaperLayer.contentsGravity = .resize
            wallpaperLayer.contentsScale = window?.backingScaleFactor ?? 2
            containerLayer.addSublayer(wallpaperLayer)
            wallpaper = wallpaperLayer

            let tintLayer = CALayer()
            containerLayer.addSublayer(tintLayer)
            tint = tintLayer

            backdrop = layer?.sublayers?.first { $0 is CABackdropLayer } as? CABackdropLayer
        }

        wallpaper?.contents = image
        currentWallpaperPath = modifiedWallpaperURL
        needsLayout = true
    }

    /// Applies the current ``effect`` to the tint layer.
    private func applyEffect() {
        guard let tint else {
            return
        }
        tint.backgroundColor = effect.tintColor().cgColor
        backdrop?.isHidden = true
    }
}

// MARK: - Logger

private extension Logger {
    /// The logger to use for the menu bar appearance manager.
    static let appearanceManager = Logger(category: "MenuBarAppearanceManager")

    /// The logger to use for the transparent menu bar.
    static let transparentMenuBar = Logger(category: "MenuBarTransparentBackdropView")
}
