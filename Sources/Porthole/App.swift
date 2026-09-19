import AppKit
import SwiftUI

struct PortholeApp: App {
    @StateObject private var store = Store()
    @AppStorage("showCount") private var showCount = true

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(store)
        } label: {
            Image(nsImage: MenuBarIcon.image(active: !store.servers.isEmpty))
            if showCount && !store.servers.isEmpty {
                Text(verbatim: String(store.servers.count))
            }
        }
        .menuBarExtraStyle(.window)
    }
}

/// Renders the panel to a PNG without opening any window. Used for README
/// screenshots and for checking the design: `Porthole --snapshot out.png`.
@MainActor
enum Snapshot {
    static func render(to path: String, dark: Bool, expand: Int?, demo: Bool) {
        _ = NSApplication.shared
        let store = Store(startTimer: false)
        if demo { store.show(DemoData.result()) } else { store.refreshNow() }
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
            print("Could not render the snapshot."); return
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("Wrote \(path)")
    }
}
