import SwiftUI

/// A row of illustrated tiles for choosing one of a few settings, in place
/// of a segmented control: each tile draws what its choice does (a pulse's
/// height, where the glide starts, how dense it is), and the chosen one
/// glows.
struct VisualChoice<Value: Hashable>: View {
    struct Option: Identifiable {
        var value: Value
        var title: String
        var art: ChoiceArt
        var id: Value { value }
    }

    var options: [Option]
    @Binding var selection: Value
    /// After a choice is made, e.g. to let it be felt.
    var onPick: (Value) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(options) { option in
                tile(option)
            }
        }
    }

    private func tile(_ option: Option) -> some View {
        let selected = option.value == selection
        return Button {
            selection = option.value
            onPick(option.value)
        } label: {
            VStack(spacing: 6) {
                ChoiceArtView(art: option.art, highlighted: selected)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(selected ? 0.10 : 0.05))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: selected ? 2 : 1)
                    )
                    .shadow(color: selected ? Color.accentColor.opacity(0.45) : .clear, radius: 5)
                Text(option.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// What a choice tile draws.
enum ChoiceArt: Hashable {
    /// One haptic pulse; `level` 0…1 is its height.
    case pulse(level: Double)
    /// Scrolling speed left to right: silent until `start` (0…1), then glide pulses.
    case threshold(start: Double)
    /// Glide pulses at a density, 0…1.
    case density(level: Double)
}

struct ChoiceArtView: View {
    var art: ChoiceArt
    var highlighted: Bool

    var body: some View {
        Canvas { context, size in
            let ink = highlighted ? Color.accentColor : Color.secondary.opacity(0.75)
            let faint = Color.secondary.opacity(0.35)
            let inset: CGFloat = 12
            let left = inset, right = size.width - inset
            let baseline = size.height * 0.68
            switch art {
            case let .pulse(level):
                // A bell-shaped pulse on a baseline; stronger is taller, and
                // the strongest carries a soft halo.
                var path = Path()
                let steps = 48
                let width = right - left
                let peak = (size.height * 0.52) * level + 3
                for step in 0...steps {
                    let x = Double(step) / Double(steps)
                    let bell = exp(-pow((x - 0.5) / 0.11, 2))
                    let point = CGPoint(x: left + width * x, y: baseline - peak * bell)
                    step == 0 ? path.move(to: point) : path.addLine(to: point)
                }
                if level > 0.9, highlighted {
                    context.stroke(path, with: .color(ink.opacity(0.35)), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                }
                context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            case let .threshold(start):
                // Dashes while scrolling is slow and silent, then dots that
                // close up as speed rises.
                let split = left + (right - left) * start
                var quiet = Path()
                quiet.move(to: CGPoint(x: left, y: baseline))
                quiet.addLine(to: CGPoint(x: split - 4, y: baseline))
                context.stroke(quiet, with: .color(faint), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 3]))
                var tick = Path()
                tick.move(to: CGPoint(x: split, y: baseline - 9))
                tick.addLine(to: CGPoint(x: split, y: baseline + 5))
                context.stroke(tick, with: .color(ink), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                var x = split + 7
                var gap: CGFloat = 10
                while x < right {
                    context.fill(Path(ellipseIn: CGRect(x: x - 2, y: baseline - 2, width: 4, height: 4)), with: .color(ink))
                    x += gap
                    gap = max(gap * 0.9, 6.5)
                }

            case let .density(level):
                // Evenly spaced glide pulses: more, larger dots for livelier.
                let count = Int(4 + level * 6)
                let radius = 1.6 + level * 1.2
                let spacing = (right - left) / CGFloat(count - 1)
                for index in 0..<count {
                    let center = CGPoint(x: left + spacing * CGFloat(index), y: baseline - 3)
                    let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                    if level > 0.9, highlighted {
                        context.fill(Path(ellipseIn: rect.insetBy(dx: -2, dy: -2)), with: .color(ink.opacity(0.25)))
                    }
                    context.fill(Path(ellipseIn: rect), with: .color(ink))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// Settings' action buttons ("Test Feedback", "Feel a Fling"…) in the same
/// family as the choice tiles: a soft tile with a coloured icon that lights
/// on hover and glows as it's pressed.
struct PulseActionButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, compact: compact)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let compact: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                .padding(.horizontal, compact ? 9 : 12)
                .padding(.vertical, compact ? 4 : 6)
                .background(
                    RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
                        .fill(pressed ? Color.accentColor.opacity(0.20) : Color.primary.opacity(hovering ? 0.10 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: compact ? 7 : 9, style: .continuous)
                        .strokeBorder(
                            pressed ? Color.accentColor : (hovering ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12)),
                            lineWidth: pressed ? 1.5 : 1
                        )
                )
                .shadow(color: pressed ? Color.accentColor.opacity(0.45) : .clear, radius: 5)
                .scaleEffect(pressed ? 0.97 : 1)
                .opacity(isEnabled ? 1 : 0.45)
                .animation(.easeOut(duration: 0.12), value: pressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .contentShape(Rectangle())
                .onHover { hovering = $0 && isEnabled }
        }
    }
}

/// An action button's label: an accent-coloured icon, then the title.
struct PulseActionLabel: View {
    enum Icon {
        case symbol(String)
        /// Pulse's own mark.
        case pulse
    }

    var title: String
    var icon: Icon

    var body: some View {
        HStack(spacing: 6) {
            Group {
                switch icon {
                case let .symbol(name):
                    Image(systemName: name).font(.system(size: 11, weight: .semibold))
                case .pulse:
                    SoftPulseShape()
                        .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 16, height: 8)
                }
            }
            .foregroundStyle(Color.accentColor)
            Text(title).foregroundStyle(.primary)
        }
    }
}

/// The Soft Pulse symbol as a SwiftUI shape, fitted to its rect (stroke it).
struct SoftPulseShape: Shape {
    func path(in rect: CGRect) -> Path {
        // The symbol's line runs x 28-228, y 82-170 on its 256 grid.
        let sx = rect.width / 200, sy = rect.height / 88
        var transform = CGAffineTransform(translationX: rect.minX - 28 * sx, y: rect.minY - 82 * sy).scaledBy(x: sx, y: sy)
        return Path(PulseLogo.symbolPath().copy(using: &transform) ?? PulseLogo.symbolPath())
    }
}
