import SwiftUI
import HandoffCore

enum Studio {
    static let canvas = Color(red: 0.082, green: 0.090, blue: 0.102)
    static let sidebar = Color(red: 0.104, green: 0.115, blue: 0.129)
    static let surface = Color(red: 0.126, green: 0.139, blue: 0.153)
    static let raised = Color(red: 0.158, green: 0.172, blue: 0.187)
    static let line = Color.white.opacity(0.085)
    static let text = Color(red: 0.91, green: 0.94, blue: 0.96)
    static let muted = Color(red: 0.56, green: 0.61, blue: 0.65)
    static let teal = Color(red: 0.39, green: 0.84, blue: 0.73)
    static let amber = Color(red: 0.98, green: 0.73, blue: 0.38)
    static let red = Color(red: 1, green: 0.47, blue: 0.43)
    static let body = Font.system(size: 12)
    static let mono = Font.system(size: 11, weight: .medium, design: .monospaced)
    static let label = Font.system(size: 10, weight: .semibold, design: .monospaced)

    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .decimal)
    }
    static func elapsed(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
    static func color(_ state: ArchiveState) -> Color {
        switch state {
        case .verified: return teal
        case .failed: return red
        case .interrupted: return amber
        case .queued: return muted
        default: return teal
        }
    }
}

struct StudioButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, danger }
    var kind: Kind = .secondary
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: 31)
            .background(background.opacity(configuration.isPressed ? 0.7 : 1))
            .brightness(hovered && enabled ? 0.035 : 0)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(kind == .primary ? Color.clear : Studio.line, lineWidth: 1))
            .opacity(enabled ? 1 : 0.35)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
    private var foreground: Color {
        switch kind { case .primary: return Studio.canvas; case .danger: return Studio.red; default: return Studio.text }
    }
    private var background: Color {
        switch kind { case .primary: return Studio.teal; case .quiet: return .clear; case .danger: return Studio.red.opacity(0.09); case .secondary: return Studio.raised }
    }
}

struct Eyebrow: View {
    var title: String
    var color: Color = Studio.muted
    var body: some View { Text(title).font(Studio.label).tracking(1.1).foregroundStyle(color) }
}

struct StatusTag: View {
    var title: String
    var color: Color = Studio.teal
    var icon: String? = nil
    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.5)
        }
        .foregroundStyle(color).padding(.horizontal, 7).padding(.vertical, 5)
        .background(color.opacity(0.09)).clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityElement(children: .combine)
    }
}

struct Metric: View {
    var label: String
    var value: String
    var detail: String? = nil
    var tint: Color = Studio.text
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Eyebrow(title: label)
            Text(value).font(.system(size: 23, weight: .medium, design: .monospaced)).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.75)
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(Studio.muted).lineLimit(2) }
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}

struct StudioPanel<Content: View>: View {
    var title: String
    var accessory: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Eyebrow(title: title); Spacer(); if let accessory { Text(accessory).font(Studio.mono).foregroundStyle(Studio.muted) } }
                .padding(.horizontal, 16).padding(.vertical, 13)
            Rectangle().fill(Studio.line).frame(height: 1)
            content
        }.background(Studio.surface).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Studio.line, lineWidth: 1))
    }
}

struct Notice: View {
    var title: String
    var text: String
    var color: Color = Studio.amber
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: color == Studio.red ? "exclamationmark.octagon" : "exclamationmark.triangle").font(.system(size: 15)).foregroundStyle(color).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                Eyebrow(title: title, color: color)
                Text(text).font(Studio.body).foregroundStyle(Studio.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }.padding(14).background(color.opacity(0.06))
            .overlay(alignment: .leading) { Rectangle().fill(color.opacity(0.7)).frame(width: 2) }
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct FineProgress: View {
    var value: Double
    var color: Color = Studio.teal
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.07))
                Capsule().fill(color).frame(width: geometry.size.width * min(1, max(0, value)))
            }
        }.frame(height: 5).accessibilityValue("\(Int(min(1, max(0, value)) * 100)) percent")
    }
}

struct HoverSurface: ViewModifier {
    @State private var hovered = false
    func body(content: Content) -> some View {
        content.background(hovered ? Color.white.opacity(0.025) : Color.clear).onHover { hovered = $0 }
    }
}

extension View {
    func studioField() -> some View {
        self.textFieldStyle(.plain).font(Studio.mono).foregroundStyle(Studio.text)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Studio.canvas).clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Studio.line, lineWidth: 1))
    }
}

struct StudioTextField: View {
    let placeholder: String
    @Binding var text: String
    let label: String
    @FocusState private var focused: Bool
    var body: some View {
        TextField(placeholder, text: $text)
            .focused($focused)
            .studioField()
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(focused ? Studio.teal.opacity(0.7) : Color.clear, lineWidth: 1))
            .accessibilityLabel(label)
    }
}
