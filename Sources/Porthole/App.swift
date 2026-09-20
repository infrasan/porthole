import AppKit
import Combine
import SwiftUI

struct PortholeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // The app lives in the menu bar; the delegate owns the status item and
        // panel. This scene exists so SwiftUI has an App body at all.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["showCount": true])
        #if DEBUG
        let demo = ProcessInfo.processInfo.environment["PORTHOLE_DEMO_PANEL"] != nil
        store = Store(startTimer: !demo)
        if demo {
            let count = ProcessInfo.processInfo.environment["PORTHOLE_DEMO_COUNT"].flatMap(Int.init)
            store.show(DemoData.result(count: count))
            store.preview(health: DemoData.health, recents: DemoData.recents)
        }
        #else
        store = Store()
        #endif

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        panelController = PanelController(store: store, statusItem: statusItem)

        HotKeyManager.shared.onFire = { [weak self] in self?.panelController.toggle() }
        if store.live { HotKeyManager.shared.registerIfEnabled() }
        if let error = HotKeyManager.shared.error { store.actionError = error }

        // objectWillChange fires mid-update; hop to the next runloop tick so the
        // menu bar reads settled state.
        store.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItem() } }
            .store(in: &cancellables)
        updateStatusItem()

        #if DEBUG
        // Dev hook for screenshot tests: PORTHOLE_OPEN_PANEL=1 Porthole
        if ProcessInfo.processInfo.environment["PORTHOLE_OPEN_PANEL"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.panelController.show() }
        }
        #endif
    }

    @objc private func statusItemClicked() {
        panelController.toggle()
    }

    /// Clicking away dismisses the panel — but only when none of our own
    /// windows (a menu, the stop confirmation) has taken key status.
    func applicationDidResignActive(_ notification: Notification) {
        if NSApp.keyWindow == nil { panelController.close() }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let showCount = UserDefaults.standard.bool(forKey: "showCount")
        let servers = store.servers
        let orphanBadge = !store.orphans.isEmpty

        if let pinned = store.pinnedPort {
            let server = store.pinnedServer
            let up = store.pinnedHealth?.isUp == true
            button.image = MenuBarIcon.image(filled: up, badge: orphanBadge)
            button.title = store.pinned?.groupID == nil ? String(pinned) : String((store.pinned?.name ?? "Project").prefix(18))
            if let server {
                button.toolTip = "\(server.name) on port \(pinned) \(store.pinnedHealth == .unknown || store.pinnedHealth == .checking ? "has not been checked yet" : up ? "is up" : "is not responding")."
            } else {
                button.toolTip = "Nothing is listening on port \(pinned)."
            }
        } else {
            button.image = MenuBarIcon.image(filled: !servers.isEmpty, badge: orphanBadge)
            button.title = showCount && !servers.isEmpty ? String(servers.count) : ""
            let count = servers.count
            button.toolTip = count == 0 ? "Porthole — no dev servers" : "Porthole — \(count) dev \(count == 1 ? "server" : "servers")"
        }
    }
}

/// The panel under the status item. MenuBarExtra can't be opened
/// programmatically, which the global hotkey needs — so the panel is ours.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    private let panel: PortholePanel
    private let statusItem: NSStatusItem
    private let hosting: NSHostingController<AnyView>
    private let store: Store
    private var sizeObserver: NSKeyValueObservation?

    init(store: Store, statusItem: NSStatusItem) {
        self.store = store
        self.statusItem = statusItem

        let hosting = NSHostingController(rootView: AnyView(PanelView().environmentObject(store)))
        // preferredContentSize tracks the SwiftUI content's fitting size and
        // updates only after layout settles, so resizing from it never races.
        hosting.sizingOptions = [.preferredContentSize]
        self.hosting = hosting
        let panel = PortholePanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        self.panel = panel

        // Popover material behind the SwiftUI content, masked to rounded corners.
        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        effect.material = .popover
        effect.state = .active
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel.contentView = effect
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        // Not hidesOnDeactivate: that hides the window when the app was never
        // genuinely frontmost, which is exactly the hotkey case. Closing is
        // handled in applicationDidResignActive instead.
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        super.init()
        panel.delegate = self
        sizeObserver = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] hosting, _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible else { return }
                self.resizeToFit(size: hosting.preferredContentSize, keepTop: true)
            }
        }
    }

    var isOpen: Bool { panel.isVisible }

    func toggle() {
        panel.isVisible ? close() : show()
    }

    func show() {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        store.panelMaxHeight = max(200, (screen?.visibleFrame.height ?? 800) - 16)
        resizeToFit(size: hosting.preferredContentSize, keepTop: false)
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        store.isPanelOpen = true
    }

    func close() {
        guard panel.isVisible else { return }
        panel.close()
        store.isPanelOpen = false
    }

    /// Sync the scan cadence when the panel loses key status. Closing itself
    /// happens in applicationDidResignActive, which knows about our menus.
    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.keyWindow == nil, !NSApp.isActive else { return }
            self.close()
        }
    }

    /// Re-fits the panel to the content. When it is already showing, keep the
    /// top edge pinned under the menu bar instead of growing downwards from
    /// the bottom-left origin AppKit anchors to.
    private func resizeToFit(size: CGSize, keepTop: Bool) {
        let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let height = size.height > 0 ? size.height : hosting.view.fittingSize.height
        panel.setContentSize(NSSize(width: PanelStyle.width, height: min(store.panelMaxHeight, max(60, height))))
        if keepTop { panel.setFrameTopLeftPoint(topLeft) }
        // Rounded corners that the shadow follows.
        if let effect = panel.contentView as? NSVisualEffectView {
            let size = effect.bounds.size
            if size.width > 0, size.height > 0 {
                effect.maskImage = NSImage(size: size, flipped: false) { rect in
                    NSColor.black.set()
                    NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
                    return true
                }
            }
        }
    }

    private func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            panel.center()
            return
        }
        let rect = buttonWindow.convertToScreen(button.frame)
        var origin = CGPoint(x: rect.midX - panel.frame.width / 2, y: rect.minY - panel.frame.height - 6)
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - panel.frame.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }
        panel.setFrameOrigin(origin)
    }
}

/// A borderless panel that can still become key, so arrow-key navigation works.
private final class PortholePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Renders the panel to a PNG without opening any window. Used for README
/// screenshots and for checking the design: `Porthole --snapshot out.png`.
@MainActor
enum Snapshot {
    static func render(to path: String, dark: Bool, expand: Int?, demo: Bool) throws {
        _ = NSApplication.shared
        let store = Store(startTimer: false)
        if demo {
            store.show(DemoData.result())
            store.preview(health: DemoData.health, recents: DemoData.recents)
        } else {
            store.refreshNow()
        }
        let expandedID = expand.flatMap { port in store.servers.first { $0.ports.contains { $0.port == port } }?.id }
        let view = PanelView(expandedID: expandedID, showOthers: true)
            .environmentObject(store)
            .environment(\.isSnapshot, true)
            .environment(\.colorScheme, dark ? .dark : .light)
            .background(dark ? Color(white: 0.17) : Color(white: 0.97))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw LaunchError.message("Could not render the snapshot.")
        }
        try png.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }
}
