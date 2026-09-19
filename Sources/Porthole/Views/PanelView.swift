import AppKit
import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.isSnapshot) private var isSnapshot
    @AppStorage("showCount") private var showCount = true
    @State var expandedID: String?
    @State var showOthers = false
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.owners.count > 1 { filters }
            Divider().opacity(0.6)
            if store.servers.isEmpty { empty } else { list }
            if !store.others.isEmpty { others }
            if store.servers.count > 1 { footer }
        }
        .frame(width: 400)
        .background {
            if !isSnapshot { WindowKeyObserver { store.isPanelOpen = $0 } }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if !store.orphans.isEmpty {
                Text("\(store.orphans.count) orphaned")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.orange)
            }
            Spacer()
            HStack(spacing: 0) {
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(IconButtonStyle())
                    .keyboardShortcut("r")
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
                settings
            }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    private var title: String {
        switch store.servers.count {
        case 0: return "No dev servers"
        case 1: return "1 dev server"
        default: return "\(store.servers.count) dev servers"
        }
    }

    @ViewBuilder private var settings: some View {
        if isSnapshot {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 26, height: 24)
        } else {
            Menu {
                Toggle("Show count in menu bar", isOn: $showCount)
                Toggle("Open at login", isOn: Binding(get: { store.launchesAtLogin }, set: { store.launchesAtLogin = $0 }))
                Divider()
                Button("Quit Porthole") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 24)
            .help("Settings")
        }
    }

    // MARK: - Filters

    private var filters: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            FilterChip(title: "All", count: store.servers.count, owner: nil, selected: store.ownerFilter == nil) {
                store.ownerFilter = nil
            }
            ForEach(store.owners, id: \.owner.id) { entry in
                FilterChip(title: entry.owner.name, count: entry.count, owner: entry.owner,
                           selected: store.ownerFilter == entry.owner.id) {
                    store.ownerFilter = store.ownerFilter == entry.owner.id ? nil : entry.owner.id
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - List

    private var rows: some View {
        VStack(spacing: 1) {
            ForEach(store.visibleServers) { server in
                ServerRow(server: server, expandedID: $expandedID)
            }
        }
        .padding(6)
    }

    @ViewBuilder private var list: some View {
        if isSnapshot {
            rows
        } else {
            ScrollView {
                rows.background(GeometryReader { geo in
                    Color.clear.preference(key: HeightKey.self, value: geo.size.height)
                })
            }
            .frame(height: min(max(listHeight, 60), 470))
            .onPreferenceChange(HeightKey.self) { listHeight = $0 }
        }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(nsImage: MenuBarIcon.image(active: false))
                .resizable()
                .frame(width: 30, height: 30)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text("Nothing is listening")
                .font(.system(size: 13, weight: .semibold))
            Text("Dev servers you or an agent start will show up here.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Other listeners

    private var others: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.6)
            Button {
                withAnimation(.easeOut(duration: 0.16)) { showOthers.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(showOthers ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text("Apps and system")
                    Text(verbatim: String(store.others.count)).foregroundStyle(.secondary)
                    Spacer()
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showOthers {
                VStack(spacing: 1) {
                    ForEach(store.others) { OtherRow(server: $0) }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        let visible = store.visibleServers
        return VStack(spacing: 0) {
            Divider().opacity(0.6)
            HStack(spacing: 8) {
                if !store.orphans.isEmpty {
                    let n = store.orphans.count
                    ConfirmButton(title: "Stop \(n) orphaned", confirmTitle: "Stop \(n) orphaned \(n == 1 ? "server" : "servers")?", tint: .orange) {
                        store.stop(store.orphans)
                    }
                }
                Spacer()
                if visible.count > 1 {
                    ConfirmButton(title: store.ownerFilter == nil ? "Stop all" : "Stop these \(visible.count)",
                                  confirmTitle: "Stop \(visible.count) servers?") {
                        store.stop(visible)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }
}

struct OtherRow: View {
    @EnvironmentObject private var store: Store
    let server: DevServer

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: String(server.primaryPort))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                if server.ports.count > 1 {
                    Text(verbatim: "+\(server.ports.count - 1)").font(.system(size: 10, weight: .medium, design: .monospaced))
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: 52, alignment: .leading)
            .help(server.ports.map { String($0.port) }.joined(separator: ", "))
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let note = server.note {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if store.stopping.contains(server.id) {
                ProgressView().controlSize(.small)
            } else if server.kind != .system {
                ConfirmButton(title: server.kind == .app ? "Quit" : "Stop", confirmTitle: server.kind == .app ? "Quit?" : "Stop?") {
                    store.stop(server)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contextMenu { ServerMenu(server: server) }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Reports whether the menu bar panel is showing. MenuBarExtra keeps its view
/// alive between openings, so onAppear alone is not reliable.
struct WindowKeyObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ObserverView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ObserverView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            let center = NotificationCenter.default
            tokens.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in self?.onChange?(true) })
            tokens.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.onChange?(false) })
            DispatchQueue.main.async { [weak self, weak window] in self?.onChange?(window?.isKeyWindow ?? false) }
        }
    }
}
