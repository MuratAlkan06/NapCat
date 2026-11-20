import AppKit
import SwiftUI

/// The pane the Settings window shows. Its own small observable, so a pane
/// switch re-renders the window content without a model publish.
@MainActor
final class SettingsSelection: ObservableObject {
    @Published var pane: SettingsPane

    init(pane: SettingsPane) {
        self.pane = pane
    }
}

/// The Settings window's three AppKit side effects, injectable so a test can
/// build the window without ever putting it on screen or activating the test
/// runner.
@MainActor
struct SettingsWindowHooks {
    /// Runs BEFORE the window is ordered front: an LSUIElement app is not
    /// active when the user reaches for it, and a window ordered front by an
    /// inactive app opens behind the frontmost app's windows.
    var activate: () -> Void
    var present: (NSWindow) -> Void
    /// Runs as the window closes: hand focus back to the app the user came
    /// from, instead of leaving NapCat active with no window at all.
    var afterClose: () -> Void

    static var live: SettingsWindowHooks {
        SettingsWindowHooks(
            activate: { NSApp.activate() },
            present: { $0.makeKeyAndOrderFront(nil) },
            afterClose: { NSApp.hide(nil) }
        )
    }
}

/// The Settings window (Panel 2.0 slice W, issue #78): a managed NSWindow —
/// NapCat runs on a plain NSApplication + AppDelegate with no SwiftUI `App`,
/// and a SwiftUI `Settings` scene (with `openSettings`) exists only inside
/// one. Preference-style toolbar tabs (`SettingsPane`), the title is the
/// active pane, the content is `SettingsRootView` at a fixed width, and the
/// last pane is restored from `DefaultsKey.settingsSelectedPane`.
///
/// Activation (LSUIElement): the app stays `.accessory` throughout — it is
/// never promoted to a regular app for the window's sake, so it never gains a
/// Dock tile or an app-switcher entry to leave behind. `show()` activates
/// first, then orders the window front; closing hands focus back
/// (`SettingsWindowHooks`). The window is not miniaturizable (an accessory
/// app's minimised window would be a Dock tile with no app behind it) and not
/// resizable (the width is fixed; the height follows the pane).
///
/// Built lazily on the first `show()` and kept for reuse — closing only
/// orders it out. Every time it becomes key, `onBecameKey` runs the owner's
/// reconciliation (MenuContentView mirrors its menu-open refresh), so the
/// panes always render freshly observed state.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private let model: MenuStateModel
    private let defaults: UserDefaults
    private let hooks: SettingsWindowHooks
    let selection: SettingsSelection
    /// The owner's refresh, run every time the window becomes key.
    var onBecameKey: (() -> Void)?
    private(set) var window: NSWindow?

    init(model: MenuStateModel, defaults: UserDefaults, hooks: SettingsWindowHooks = .live) {
        self.model = model
        self.defaults = defaults
        self.hooks = hooks
        selection = SettingsSelection(pane: SettingsPane.restored(
            stored: defaults.object(forKey: DefaultsKey.settingsSelectedPane),
            available: model.settingsPanes))
        super.init()
    }

    /// Opens the window — or brings it back — on the current pane:
    /// activation first, then the window.
    func show() {
        let window = self.window ?? makeWindow()
        hooks.activate()
        hooks.present(window)
    }

    /// A toolbar click: show the pane, title the window after it, and store
    /// it for the next launch. Panes this wiring does not show are ignored.
    func select(_ pane: SettingsPane) {
        guard model.settingsPanes.contains(pane) else { return }
        selection.pane = pane
        defaults.set(pane.rawValue, forKey: DefaultsKey.settingsSelectedPane)
        applyTitle()
        window?.toolbar?.selectedItemIdentifier = Self.toolbarIdentifier(pane)
    }

    static func toolbarIdentifier(_ pane: SettingsPane) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("settings.\(pane.rawValue)")
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsRootView(model: model, selection: selection))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsMetrics.width, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        // The hosting view's constraints hold the window to the content's
        // fitting size (fixed width, the pane's height).
        window.contentViewController = hosting

        let toolbar = NSToolbar(identifier: "com.muratalkan.napcat.settings")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbarStyle = .preference
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = Self.toolbarIdentifier(selection.pane)

        self.window = window
        applyTitle()
        window.center()
        return window
    }

    private func applyTitle() {
        let title = selection.pane.title
        window?.contentViewController?.title = title
        window?.title = title
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        onBecameKey?()
    }

    func windowWillClose(_ notification: Notification) {
        hooks.afterClose()
    }

    // MARK: NSToolbarDelegate

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = SettingsPane.allCases.first(where: { Self.toolbarIdentifier($0) == itemIdentifier }) else {
            return nil
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = pane.title
        item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        item.target = self
        item.action = #selector(toolbarItemSelected(_:))
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        model.settingsPanes.map(Self.toolbarIdentifier)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        model.settingsPanes.map(Self.toolbarIdentifier)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        model.settingsPanes.map(Self.toolbarIdentifier)
    }

    @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
        guard let pane = SettingsPane.allCases.first(where: { Self.toolbarIdentifier($0) == sender.itemIdentifier }) else {
            return
        }
        select(pane)
    }
}

/// NapCat's main menu. An LSUIElement app never shows a menu bar, but while
/// it is active (the Settings window is key, a NapCat alert is up) AppKit
/// still matches key equivalents against `NSApp.mainMenu` — so this is where
/// ⌘, opens Settings from anywhere outside the status menu (the open status
/// menu carries its own hidden ⌘, item, see MenuContentView), and where the
/// Settings window gets ⌘W and ⌘Q.
enum AppMainMenu {
    @MainActor
    static func make(settingsTarget: MenuContentView) -> NSMenu {
        let appMenu = NSMenu(title: "NapCat")
        let settings = NSMenuItem(title: "Settings…", action: #selector(MenuContentView.showSettings(_:)),
                                  keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = settingsTarget
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit NapCat", action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let main = NSMenu(title: "Main")
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
            item.submenu = submenu
            main.addItem(item)
        }
        return main
    }
}
