import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

enum Format {
    /// "40s", "12m", "5h", "3d"
    static func age(since date: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        default: return "\(s / 86400)d"
        }
    }

    static func memory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private static let today: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    private static let earlier: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMMjmm")
        return f
    }()

    static func started(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? "today at \(today.string(from: date))" : earlier.string(from: date)
    }
}

/// The menu bar glyph: a porthole. The glass fills in while servers are running.
enum MenuBarIcon {
    static func image(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let c = CGPoint(x: rect.midX, y: rect.midY)
            NSColor.black.set()
            let ring = NSBezierPath(ovalIn: CGRect(x: c.x - 7.25, y: c.y - 7.25, width: 14.5, height: 14.5))
            ring.lineWidth = 1.5
            ring.stroke()
            for k in 0..<4 {
                let a = CGFloat(k) * .pi / 2 + .pi / 4
                let r: CGFloat = 5.05
                NSBezierPath(ovalIn: CGRect(x: c.x + r * cos(a) - 0.8, y: c.y + r * sin(a) - 0.8, width: 1.6, height: 1.6)).fill()
            }
            let glass = NSBezierPath(ovalIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
            if active {
                glass.fill()
            } else {
                glass.lineWidth = 1.1
                glass.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The small mark next to an owner's name. Agents fly their color.
struct OwnerMark: View {
    let owner: Owner

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 11)
    }

    private var symbol: String {
        switch owner.kind {
        case .agent: return "flag.fill"
        case .terminal: return "person.fill"
        case .app: return "macwindow"
        case .service: return "gearshape.fill"
        case .unknown: return "questionmark"
        }
    }

    private var tint: Color {
        switch owner.kind {
        case .agent, .app: return Color(hex: owner.color)
        default: return .secondary
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    var hoverTint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, hoverTint: hoverTint)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let hoverTint: Color
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hovering ? hoverTint : Color.secondary)
            .frame(width: 26, height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(hovering ? 0.09 : 0)))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
            .onHover { hovering = $0 }
    }
}

/// A text button that asks for a second click before doing something drastic.
struct ConfirmButton: View {
    let title: String
    let confirmTitle: String
    var tint: Color = .red
    let action: () -> Void
    @State private var armed = false

    var body: some View {
        Button {
            if armed { armed = false; action() } else {
                armed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { armed = false }
            }
        } label: {
            Text(armed ? confirmTitle : title)
                .font(.system(size: 11.5, weight: armed ? .semibold : .medium))
                .foregroundStyle(armed ? Color.white : tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(armed ? tint : tint.opacity(0.12)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: armed)
    }
}

struct FilterChip: View {
    let title: String
    let count: Int
    let owner: Owner?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let owner { OwnerMark(owner: owner) }
                Text(title)
                Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(selected ? 0.13 : 0.045)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(selected ? 0.16 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// True while rendering a static image (README screenshots, `--snapshot`).
/// Scroll views and menus do not render into images, so views swap them out.
private struct SnapshotKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

/// Lays chips out in rows, wrapping to a new line when one would not fit.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
