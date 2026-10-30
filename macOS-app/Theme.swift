import SwiftUI
import AppKit

// Visual identity: one colour per meaning (Palette in Core.swift, contrast checked by tests/test_core.swift),
// resolved for light and dark mode by AppKit. A status is always shown with its icon AND its label:
// never by colour alone.

extension RGB {
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
}

extension Color {
    static func dynamic(light: RGB, dark: RGB) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark.nsColor : light.nsColor
        })
    }
    static let card = Color.dynamic(light: Palette.lightCard, dark: Palette.darkCard)
    static let canvasTop = Color.dynamic(light: RGB(0xEEF0FB), dark: RGB(0x111222))
    static let canvasBottom = Color.dynamic(light: RGB(0xF7F3FB), dark: RGB(0x171528))
    static let cardStroke = Color.dynamic(light: RGB(0xE3E5F0), dark: RGB(0x2E3150))
    static let logBackground = Color.dynamic(light: RGB(0xF6F7FB), dark: RGB(0x15172A))
    static let subtle = Color.dynamic(light: RGB(0x5B6170), dark: RGB(0xA9AEC2))
}

extension Tone {
    var fg: Color { .dynamic(light: Palette.foreground(self, dark: false), dark: Palette.foreground(self, dark: true)) }
    var bg: Color { .dynamic(light: Palette.background(self, dark: false), dark: Palette.background(self, dark: true)) }
}

enum Brand {
    static var gradient: LinearGradient {
        LinearGradient(colors: Palette.gradient.map { Color(nsColor: RGB($0).nsColor) }, startPoint: .leading, endPoint: .trailing)
    }
    static func gradientColors() -> [Color] { Palette.gradient.map { Color(nsColor: RGB($0).nsColor) } }
    // gradient under white text: same darkening veil as the header (contrast >= 4.5 checked by the tests)
    static var veiled: some View { ZStack { gradient; Color.black.opacity(Palette.headerVeil) } }
}

// ---------- pills ----------
struct Pill: View {
    let label: String
    let symbol: String
    let tone: Tone
    var spinning = false
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            if spinning {
                ProgressView().controlSize(.mini).tint(tone.fg)
            } else {
                Image(systemName: symbol).font(.system(size: compact ? 10 : 11, weight: .bold))
            }
            Text(label).font(.system(size: compact ? 10.5 : 11.5, weight: .semibold)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(tone.fg)
        .padding(.horizontal, compact ? 7 : 9)
        .padding(.vertical, compact ? 2.5 : 4)
        .background(Capsule().fill(tone.bg))
        .overlay(Capsule().strokeBorder(tone.fg.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

struct StatusPill: View {
    let status: ResultStatus
    var compact = false
    var body: some View {
        Pill(label: status.label, symbol: status.symbol, tone: status.tone, compact: compact)
            .help(status == .unknown ? "Statut non reconnu : jamais considéré comme une réussite" : status.label)
    }
}

struct PermissionPill: View {
    let state: PermissionState
    var body: some View {
        switch state {
        case .checking: Pill(label: state.label, symbol: "hourglass", tone: state.tone, spinning: true)
        case .granted: Pill(label: state.label, symbol: "checkmark.circle.fill", tone: state.tone)
        case .denied: Pill(label: state.label, symbol: "xmark.circle.fill", tone: state.tone)
        case .error(let why): Pill(label: state.label, symbol: "exclamationmark.questionmark", tone: state.tone).help(why)
        }
    }
}

// ---------- cards ----------
struct Card<Content: View, Trailing: View>: View {
    let title: String
    let symbol: String
    var accent: Int = 0
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(_ title: String, symbol: String, accent: Int = 0,
         @ViewBuilder trailing: @escaping () -> Trailing, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.symbol = symbol; self.accent = accent; self.trailing = trailing; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                let c = Brand.gradientColors()
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [c[accent % c.count], c[(accent + 1) % c.count]],
                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Spacer(minLength: 6)
                trailing()
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.cardStroke, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }
}

extension Card where Trailing == EmptyView {
    init(_ title: String, symbol: String, accent: Int = 0, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, symbol: symbol, accent: accent, trailing: { EmptyView() }, content: content)
    }
}

// ---------- animated header (application icon, title, subtitle, counters) ----------
struct HeaderBanner<Trailing: View>: View {
    let title: String
    let subtitle: String
    let busy: Bool
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if reduceMotion {
                Brand.gradient
            } else {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    let speed = busy ? 0.35 : 0.12
                    let a = Angle.radians(t * speed)
                    LinearGradient(colors: Brand.gradientColors(),
                                   startPoint: UnitPoint(x: 0.5 + 0.5 * cos(a.radians), y: 0.5 + 0.5 * sin(a.radians)),
                                   endPoint: UnitPoint(x: 0.5 - 0.5 * cos(a.radians), y: 0.5 - 0.5 * sin(a.radians)))
                }
            }
            // darkening veil: white text stays readable on every colour of the gradient
            Color.black.opacity(Palette.headerVeil)
            HStack(alignment: .center, spacing: 14) {
                AppIconMark(busy: busy).frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 21, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    Text(subtitle).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                }
                Spacer(minLength: 10)
                trailing()
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 74)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color(nsColor: RGB(Palette.gradient[1]).nsColor).opacity(0.28), radius: 14, y: 5)
    }
}

// ---------- application icon (same vector source as AppIcon.icns: AppIconArt.swift) ----------
struct AppIconCanvas: View {
    let pose: AppIconArt.Pose
    var body: some View {
        Canvas { ctx, size in
            ctx.withCGContext { AppIconArt.draw($0, in: CGRect(origin: .zero, size: size), pose: pose) }
        }
    }
}

private struct LaunchIcon: View, Animatable {
    var progress: Double
    var animatableData: Double { get { progress } set { progress = newValue } }
    var body: some View { AppIconCanvas(pose: .launch(progress)) }
}

// at launch the arrow drops into the package, then the check pops; while a long operation runs the arrow floats
// gently. Decorative only (the header texts carry the state); with Reduce Motion: the still icon, no animation.
final class IconLaunchState: ObservableObject { @Published var progress = 0.0 }

struct AppIconMark: View {
    let busy: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var launch = IconLaunchState()

    var body: some View {
        Group {
            if busy && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    AppIconCanvas(pose: AppIconArt.Pose(arrow: CGFloat(0.06 * (0.5 + 0.5 * sin(t * 3))), badge: 1,
                                                        sparkle: CGFloat(0.55 + 0.45 * sin(t * 2.2))))
                }
            } else {
                LaunchIcon(progress: reduceMotion ? 1 : launch.progress)
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
        .accessibilityHidden(true)
        .onAppear {
            guard launch.progress < 1 else { return }
            if reduceMotion { launch.progress = 1 } else { withAnimation(.linear(duration: 1.5).delay(0.2)) { launch.progress = 1 } }
        }
    }
}

// counter shown on the header (white on a translucent capsule)
struct HeaderChip: View {
    let count: Int
    let status: ResultStatus
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol).font(.system(size: 10.5, weight: .bold))
            Text("\(count) \(status.label)").font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.28)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// ---------- progress ----------
// determinate: animated width; indeterminate: a segment sweeping back and forth (static with Reduce Motion)
struct GradientProgress: View {
    let value: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.cardStroke)
                if let v = value {
                    Capsule().fill(Brand.gradient)
                        .frame(width: max(8, g.size.width * CGFloat(min(max(v, 0), 1))))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: v)
                } else if reduceMotion {
                    Capsule().fill(Brand.gradient).frame(width: g.size.width * 0.35).offset(x: g.size.width * 0.3)
                } else {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let x = 0.325 + 0.325 * sin(t * 2.6)
                        Capsule().fill(Brand.gradient)
                            .frame(width: g.size.width * 0.35)
                            .offset(x: g.size.width * CGFloat(x))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 7)
        .accessibilityElement()
        .accessibilityLabel(value.map { "Progression \(Int($0 * 100)) %" } ?? "En cours")
    }
}

// message line (info, warning, error) inside a card
struct Notice: View {
    let tone: Tone
    let symbol: String
    let title: String
    var message: String = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tone.fg).font(.system(size: 12, weight: .bold))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(tone.fg)
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.primary.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tone.bg))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tone.fg.opacity(0.3), lineWidth: 1))
    }
}

struct GradientButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background {
                if enabled { Brand.veiled.clipShape(Capsule()) } else { Capsule().fill(Color.gray.opacity(0.45)) }
            }
            .overlay(Capsule().fill(.black.opacity(configuration.isPressed ? 0.15 : 0)))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
