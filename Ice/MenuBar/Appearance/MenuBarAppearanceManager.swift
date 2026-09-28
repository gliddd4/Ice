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

    /// The currently managed strips that hide the shadow under each menu bar.
    private var stripControllers: [MenuBarWallpaperStripController] = []

    /// The displays whose wallpaper Ice has banded, so that the wallpaper can be
    /// restored when the transparent menu bar is turned off.
    private var bandedDisplayIDs: Set<CGDirectDisplayID> = []

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

        NotificationCenter.default
            .publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.restoreOriginalWallpaper()
                }
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

    /// Configures the manager's transparent menu bar, if required by the given
    /// configuration.
    ///
    /// A transparent menu bar is made by banding the desktop wallpaper and letting the
    /// overlay panel filter the bar's backdrop, which is what shows the wallpaper there
    /// without covering the bar's own menus and status items. The only window the
    /// manager owns is the strip that hides the shadow the system draws under the bar.
    private func updateTransparentWindows(for configuration: MenuBarAppearanceConfigurationV2) {
        // Tear down anything that is no longer called for.
        guard configuration.shapeKind == .transparent else {
            tearDownTransparentWindows()
            return
        }

        // Nothing to do if Ice is already managing exactly the current screens.
        if Set(stripControllers.map(\.screen)) == Set(NSScreen.screens) {
            return
        }

        // Only tear down when there is something to tear down. Doing it on the way in
        // would restore the wallpaper that the previous run banded and then immediately
        // band it again, which is a new wallpaper file written on every launch.
        if !stripControllers.isEmpty {
            tearDownTransparentWindows()
        }

        for screen in NSScreen.screens {
            installBandedWallpaperIfNeeded(for: screen)
        }

        // The strip covers the shadow that the system draws under the menu bar, which
        // lands on top of the wallpaper everywhere else, so it is only ever needed
        // alongside a transparent menu bar.
        stripControllers = NSScreen.screens.map(MenuBarWallpaperStripController.init)
    }

    /// Closes the manager's transparent menu bar windows and restores any
    /// wallpapers they modified.
    private func tearDownTransparentWindows() {
        for controller in stripControllers {
            controller.close()
        }
        stripControllers = []

        restoreOriginalWallpaper()
    }

    /// Replaces the desktop wallpaper of the given screen with a copy that carries an
    /// opaque band across the menu bar area, remembering the wallpaper it replaced.
    ///
    /// This is what makes the menu bar transparent: the band is part of the desktop,
    /// so the bar has nothing of its own to show, and it stays put no matter what Ice
    /// does afterwards.
    private func installBandedWallpaperIfNeeded(for screen: NSScreen) {
        guard let desktopPicture = NSWorkspace.shared.desktopImageURL(for: screen) else {
            return
        }
        // Already one of Ice's own copies, so there is nothing to do. Banding it again
        // would band an image that is already banded and would lose track of the
        // wallpaper Ice replaced in the first place.
        guard !MenuBarWallpaper.isManagedWallpaper(desktopPicture) else {
            return
        }
        guard
            let source = CGImageSourceCreateWithURL(desktopPicture as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            let banded = MenuBarWallpaper.bandedImage(image, for: screen),
            let url = Wallpaper.saveWallpaper(
                NSImage(cgImage: banded, size: CGSize(width: banded.width, height: banded.height))
            )
        else {
            Logger.transparentMenuBar.error("Unable to build modified wallpaper.")
            return
        }

        MenuBarWallpaper.originalWallpaperURL = desktopPicture

        do {
            try Wallpaper.set(url, screen: screen)
            bandedDisplayIDs.insert(screen.displayID)
        } catch {
            Logger.transparentMenuBar.error("Error while setting wallpaper: \(error)")
        }
    }

    /// Restores the wallpaper that was installed before Ice banded it.
    ///
    /// Only screens that are actually showing one of Ice's own copies are touched, and
    /// the remembered wallpaper is only forgotten once it has been put back. Clearing it
    /// unconditionally would lose the wallpaper Ice replaced - and with it every trace of
    /// what the bar should show - the first time the transparent menu bar was set up.
    private func restoreOriginalWallpaper() {
        guard let url = MenuBarWallpaper.originalWallpaperURL else {
            return
        }
        var didRestore = false
        for screen in NSScreen.screens {
            guard
                let picture = NSWorkspace.shared.desktopImageURL(for: screen),
                MenuBarWallpaper.isManagedWallpaper(picture)
            else {
                continue
            }
            do {
                try Wallpaper.set(url, screen: screen)
                didRestore = true
            } catch {
                Logger.transparentMenuBar.error("Error while setting wallpaper: \(error)")
            }
        }
        if didRestore {
            MenuBarWallpaper.originalWallpaperURL = nil
            bandedDisplayIDs = []
        }
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

// MARK: - Logger

private extension Logger {
    /// The logger to use for the menu bar appearance manager.
    static let appearanceManager = Logger(category: "MenuBarAppearanceManager")

    /// The logger to use for the transparent menu bar.
    static let transparentMenuBar = Logger(category: "TransparentMenuBar")
}
