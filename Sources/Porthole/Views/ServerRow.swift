import AppKit
import SwiftUI

struct ServerRow: View {
    @EnvironmentObject private var store: Store
    let server: DevServer
    @Binding var expandedID: String?
    @State private var hovering = false

    private var expanded: Bool { expandedID == server.id }
    private var isStopping: Bool { store.stopping.contains(server.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                portColumn
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(server.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        if let framework = server.framework {
                            Text(framework.name)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    meta
                }
                Spacer(minLength: 4)
                actions
            }
            if let error = store.errors[server.id] {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.leading, 64)
                    .padding(.top, 4)
            }
            if expanded {
                ServerDetails(server: server)
                    .padding(.leading, 64)
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(expanded ? 0.06 : hovering ? 0.045 : 0))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.16)) { expandedID = expanded ? nil : server.id }
        }
        .opacity(isStopping ? 0.45 : 1)
        .animation(.easeOut(duration: 0.2), value: isStopping)
        .contextMenu { ServerMenu(server: server) }
    }

    private var portColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: String(server.primaryPort))
                .font(.system(size: 16, weight: .medium, design: .monospaced))
            if server.ports.count > 1 {
                Text(verbatim: "+\(server.ports.count - 1)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help(server.ports.map { String($0.port) }.joined(separator: ", "))
            }
        }
        .frame(width: 52, alignment: .leading)
    }

    private var meta: some View {
        HStack(spacing: 9) {
            HStack(spacing: 4) {
                OwnerMark(owner: server.owner)
                Text(server.owner.name).foregroundStyle(.primary.opacity(0.85))
            }
            .fixedSize()
            .help(server.owner.evidence)
            TimelineView(.periodic(from: .now, by: 20)) { context in
                Text(Format.age(since: server.startedAt, now: context.date))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .fixedSize()
            .help("Started \(Format.started(server.startedAt))")
            if server.isOrphaned {
                Text("orphaned")
                    .fontWeight(.medium)
                    .foregroundStyle(.orange)
                    .help("Nothing that started it is still running. It is probably safe to stop.")
            }
            if server.isExposed {
                Image(systemName: "network")
                    .foregroundStyle(.secondary)
                    .help("Reachable from other devices on your network")
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private var actions: some View {
        HStack(spacing: 0) {
            if server.canOpen {
                Button { store.open(server) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Open in browser")
                    .help("Open localhost:\(String(server.primaryPort))")
            }
            if isStopping {
                ProgressView().controlSize(.small).frame(width: 26, height: 24)
            } else {
                Button {
                    store.stop(server, force: NSEvent.modifierFlags.contains(.option))
                } label: {
                    Image(systemName: "stop.fill").font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(IconButtonStyle(hoverTint: .red))
                .accessibilityLabel(server.brewService != nil ? "Stop service" : "Stop")
                .help(server.brewService.map { "Run brew services stop \($0)" } ?? "Stop. Option-click to force quit.")
            }
        }
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }
}

struct ServerDetails: View {
    @EnvironmentObject private var store: Store
    let server: DevServer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                if let cwd = server.cwd {
                    row("Folder") {
                        Text(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                row("Command") {
                    Text(server.command)
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let via = server.launchedVia {
                    row("Run with") { Text(via).font(.system(size: 10.5, design: .monospaced)) }
                }
                row("Started") {
                    Text("\(Format.started(server.startedAt)). \(server.owner.evidence)")
                        .fixedSize(horizontal: false, vertical: true)
                }
                row("Stop ends") { chain }
                if server.memory > 0 {
                    row("Memory") { Text(Format.memory(server.memory)) }
                }
                if let url = server.networkURL(host: store.networkAddress) {
                    row("Network") { Text(url.absoluteString).textSelection(.enabled) }
                }
                if let note = server.note {
                    row("Note") { Text(note).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .font(.system(size: 11))

            HStack(spacing: 6) {
                if server.cwd != nil {
                    Button("Reveal in Finder") { store.reveal(server) }
                }
                if server.canOpen, let url = server.url {
                    Button("Copy URL") { store.copy(url.absoluteString) }
                }
                Spacer()
                Button("Force quit") { store.stop(server, force: true) }
                    .help("Send SIGKILL right away")
            }
            .controlSize(.small)
        }
    }

    private var chain: some View {
        var text = Text("")
        for (i, link) in server.chain.enumerated() {
            if i > 0 { text = text + Text("  →  ").foregroundColor(.secondary) }
            text = text + Text(link.label) + Text(verbatim: " \(link.pid)").foregroundColor(.secondary)
        }
        if server.childCount > 0 {
            let noun = server.childCount == 1 ? "child process" : "child processes"
            text = text + Text(verbatim: ", plus \(server.childCount) \(noun)").foregroundColor(.secondary)
        }
        return text.fixedSize(horizontal: false, vertical: true)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ServerMenu: View {
    @EnvironmentObject private var store: Store
    let server: DevServer

    var body: some View {
        if server.canOpen, let url = server.url {
            Button("Open \(url.host ?? "localhost"):\(String(server.primaryPort))") { store.open(server) }
            if let net = server.networkURL(host: store.networkAddress) {
                Button("Open on network (\(net.host ?? ""))") { store.openOnNetwork(server) }
                Button("Copy network URL") { store.copy(net.absoluteString) }
            }
            Button("Copy URL") { store.copy(url.absoluteString) }
        }
        if server.cwd != nil {
            Button("Reveal in Finder") { store.reveal(server) }
        }
        Button("Copy command") { store.copy(server.command) }
        Divider()
        Button(server.brewService != nil ? "Stop service" : "Stop") { store.stop(server) }
        Button("Force quit") { store.stop(server, force: true) }
    }
}
