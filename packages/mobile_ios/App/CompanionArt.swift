import SwiftUI
import UIKit

/*
 * Companion characters as theme-derived vector art, ported from the desktop
 * (`packages/desktop/src/ui/companion.zig`: renderSprout / renderMoss / renderVireo). Geometry is in
 * the desktop's 46-unit design box; colors derive from the active theme's background, text,
 * accent, border, muted panel, warning and danger exactly like the desktop palettes. Gradients are
 * sampled at their midpoint, as the desktop does.
 */

/// Linear sRGB components (0...1) for the desktop's palette math.
struct ArtColor: Equatable {
    var r: Double, g: Double, b: Double, a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    init(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(r: Double(red), g: Double(green), b: Double(blue), a: Double(alpha))
    }

    var luma: Double { r * 0.2126 + g * 0.7152 + b * 0.0722 }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    func mix(_ to: ArtColor, _ amount: Double) -> ArtColor {
        let t = min(max(amount, 0), 1)
        return ArtColor(r: r + (to.r - r) * t, g: g + (to.g - g) * t, b: b + (to.b - b) * t, a: a + (to.a - a) * t)
    }
    func alpha(_ value: Int) -> ArtColor { ArtColor(r: r, g: g, b: b, a: Double(value) / 255) }
    private func shift(_ amount: Double) -> ArtColor {
        ArtColor(r: min(max(r + amount, 0), 1), g: min(max(g + amount, 0), 1), b: min(max(b + amount, 0), 1), a: a)
    }
    /// `theme.raiseAgainst`: away from the backing (darker on light palettes).
    func raised(_ amount: Double, backing: ArtColor, foreground: ArtColor) -> ArtColor {
        backing.luma > foreground.luma ? shift(-amount) : shift(amount)
    }
    func distance(_ other: ArtColor) -> Double { abs(luma - other.luma) }
}

/// The theme roles the desktop character palettes read.
struct CharacterTheme {
    var background, text, subtle, accent, border, panelMuted, warning, danger: ArtColor

    static var current: CharacterTheme {
        CharacterTheme(background: ArtColor(VerdeTheme.background), text: ArtColor(VerdeTheme.text), subtle: ArtColor(VerdeTheme.subtle),
                       accent: ArtColor(VerdeTheme.accent), border: ArtColor(VerdeTheme.border), panelMuted: ArtColor(VerdeTheme.mutedPanel),
                       warning: ArtColor(VerdeTheme.warning), danger: ArtColor(VerdeTheme.danger))
    }
    var textIsLighter: Bool { text.luma >= background.luma }
    var poleLight: ArtColor { textIsLighter ? text : background }
    var poleDark: ArtColor { textIsLighter ? background : text }
    var charSurface: ArtColor { background.raised(0.035, backing: background, foreground: text) }
}

extension CompanionCharacter {
    /// Full-size design box (desktop `fullCharacterSize`).
    var designSize: CGSize {
        switch self {
        case .sprout: return CGSize(width: 46, height: 48)
        case .moss: return CGSize(width: 46, height: 46)
        case .vireo: return CGSize(width: 46, height: 42)
        }
    }
}

/// Draws one character at `width` points wide. Art that overhangs the 46-unit box (Vireo's tail,
/// Sprout's leaf, the failure badge) stays inside the view's padded frame.
struct CompanionAvatar: View {
    let character: CompanionCharacter
    var pose: CompanionPose = .idle
    var failure = false
    var width: CGFloat = 46
    @Environment(\.colorScheme) private var scheme

    /// Overhang in design units: left (tail/badge), top (badge), right (leaf).
    private static let inset = (left: 10.0, top: 3.0, right: 3.0)

    var body: some View {
        let s = width / 46
        let size = character.designSize
        let theme = CharacterTheme.current
        Canvas { context, _ in
            let art = ArtContext(context: context, s: Double(s), origin: CGPoint(x: Self.inset.left * Double(s), y: Self.inset.top * Double(s)))
            switch character {
            case .sprout: drawSprout(art, theme)
            case .moss: drawMoss(art, theme)
            case .vireo: drawVireo(art, theme)
            }
            if failure { drawFailureBadge(art, theme) }
        }
        .frame(width: (size.width + Self.inset.left + Self.inset.right) * s, height: (size.height + Self.inset.top) * s)
        .id(scheme) // Theme colors are read when drawing; redraw on appearance change.
        .accessibilityElement()
        .accessibilityLabel(character.displayName)
        .accessibilityValue(poseLabel)
    }

    private var poseLabel: String {
        switch pose {
        case .idle: return "Ready"
        case .working: return "Working"
        case .approval: return "Needs you"
        case .paused: return "Paused"
        }
    }

    // MARK: Sprout

    private func drawSprout(_ art: ArtContext, _ t: CharacterTheme) {
        let accentHi = t.accent.mix(t.poleLight, 0.28)
        let well = t.background.raised(0.02, backing: t.background, foreground: t.text)
        var headTop = t.text.mix(accentHi, 0.45)
        var headBottom = t.text.mix(t.accent, 0.38)
        var irisTop = t.text.mix(t.danger, 0.76)
        var irisBottom = well.mix(t.danger, 0.66)
        if irisTop.distance(headTop) < 0.18 {
            headTop = headTop.mix(t.text, 0.15)
            headBottom = headBottom.mix(t.text, 0.15)
            if irisTop.distance(headTop) < 0.18 { irisTop = t.danger; irisBottom = t.danger }
        }
        var outline = t.border.mix(t.accent, 0.55)
        if outline.distance(t.charSurface) < 0.10 {
            outline = t.border
            if outline.distance(t.charSurface) < 0.10 { outline = t.subtle }
        }
        var stem = t.charSurface.mix(t.accent, 0.85)
        var bladeStart = t.accent
        var bladeEnd = t.accent.mix(accentHi, 0.75)
        let torsoTop = t.text.mix(accentHi, 0.38)
        let torsoBottom = t.text.mix(t.accent, 0.34)
        let torsoFill = torsoTop.mix(torsoBottom, 0.5)
        if bladeStart.mix(bladeEnd, 0.5).distance(torsoFill) < 0.06 {
            let fallback = t.accent.mix(t.poleDark, 0.15)
            stem = fallback; bladeStart = fallback; bladeEnd = fallback
        }
        let headFill = headTop.mix(headBottom, 0.5)
        let feet = t.text.mix(t.accent, 0.30)
        let highlight = t.poleLight.alpha(64)
        let headDepth = t.poleDark.alpha(36)
        let torsoDepth = t.poleDark.alpha(31)
        let eyeRing = well.mix(t.danger, 0.40)
        let catchPrimary = t.danger.mix(t.poleLight, 0.90)
        let catchSecondary = t.danger.mix(t.poleLight, 0.70).alpha(204)
        let pausedLid = t.danger.mix(well, 0.70)
        let buds = t.panelMuted.mix(t.accent, 0.62)
        let mouth = t.accent.mix(well, 0.65)

        // Crown leaf: a short stem and a blade sweeping right.
        art.rect(17, 7, 3, 9, stem, 1.5)
        let droop = pose == .paused ? 4.0 : 0
        let leaf = [(19.0, 10 + droop), (48.0, 3 + droop), (45.0, 14 + droop), (23.0, 16 + droop)]
        let leafColor = bladeStart.mix(bladeEnd, 0.5)
        art.triangle(leaf[0], leaf[1], leaf[2], leafColor)
        art.triangle(leaf[0], leaf[2], leaf[3], leafColor)

        // Torso and perch feet.
        let torso = (x: 12.0, y: 35.0, w: 22.0, h: 13.0)
        art.rect(torso.x, torso.y + 3, torso.w, torso.h, torsoDepth, 6)
        art.panel(torso.x, torso.y, torso.w, torso.h, torsoFill, outline, 6, 1)
        art.rect(torso.x + 0.5, torso.y + torso.h - 2, 7, 4, feet, 2)
        art.rect(torso.x + torso.w - 7.5, torso.y + torso.h - 2, 7, 4, feet, 2)

        // Head.
        let face = (x: 5.0, y: 12.0, w: 36.0, h: 27.0)
        art.rect(face.x, face.y + 3, face.w, face.h, headDepth, 13)
        art.panel(face.x, face.y, face.w, face.h, headFill, outline, 13, 1)
        art.clippedRect(face.x + 5, face.y + 3, face.w - 10, 2, highlight, 1, clip: (face.x, face.y, face.w, face.h, 13))

        let eyeY = face.y + 7
        for eyeX in [face.x + 8, face.x + 19.5] {
            if pose == .paused {
                art.rect(eyeX, eyeY + 4, 8.5, 2, pausedLid, 1)
            } else {
                art.panel(eyeX, eyeY, 8.5, 9, irisTop.mix(irisBottom, 0.5), eyeRing, 4.25, 1)
                let gaze = pose == .approval ? 2.0 : 0
                art.rect(eyeX + 2.5 + gaze, eyeY + 3, 3.5, 4, eyeRing, 1.7)
                art.rect(eyeX + 1.7, eyeY + 1.4, 3, 3, catchPrimary, 1.5)
                art.rect(eyeX + 5.4, eyeY + 5.9, 1.7, 1.7, catchSecondary, 0.85)
            }
        }
        for offset in [-5.5, 0, 5.5] {
            art.rect(face.x + face.w * 0.5 + offset - 1.5, face.y + face.h - 2, 3, 3, buds, 1.5)
        }
        art.line((face.x + 14.5, face.y + 20.5), (face.x + 18, face.y + 22), 1.2, mouth)
        art.line((face.x + 18, face.y + 22), (face.x + 21.5, face.y + 20.5), 1.2, mouth)
    }

    // MARK: Moss

    private func drawMoss(_ art: ArtContext, _ t: CharacterTheme) {
        let surfaceDeep = t.background.mix(t.poleDark, 0.18)
        let panel = t.background.mix(t.panelMuted, 0.55)
        let warmAccent = t.accent.mix(t.warning, 0.30)
        let bronze = t.panelMuted.mix(warmAccent, 0.16)
        var outline = t.border.mix(warmAccent, 0.22)
        if outline.distance(bronze) < 0.10 {
            outline = t.border
            if outline.distance(bronze) < 0.10 { outline = t.subtle }
        }
        let body = bronze
        let bodyDepth = t.poleDark.alpha(34)
        let mossDeep = t.accent.mix(surfaceDeep, 0.28)
        let mossMid = t.accent.mix(panel, 0.12)
        let mossLit = t.accent.mix(t.poleLight, 0.28).mix(t.accent, 0.42)
        let port = t.warning.mix(surfaceDeep, 0.94)
        let portRing = surfaceDeep.mix(t.warning, 0.28)
        let pupil = t.warning.mix(t.poleLight, 0.22)
        let seam = surfaceDeep.mix(t.warning, 0.20)
        let flower = t.poleLight.mix(t.warning, 0.18)
        let pausedLid = surfaceDeep.mix(t.warning, 0.35)
        let tilt = pose == .approval ? 1.2 : 0
        let drop = pose == .paused ? 1.0 : 0

        // Shoulders and resting hands.
        let torso = (x: 0.0, y: 26.0, w: 46.0, h: 20.0)
        art.rect(torso.x, torso.y + 2, torso.w, torso.h, bodyDepth, 10)
        art.panel(torso.x, torso.y, torso.w, torso.h, body, outline, 10, 1)
        art.rect(torso.x + 3, torso.y + torso.h - 3, 9, 6, body, 4)
        art.rect(torso.x + torso.w - 12, torso.y + torso.h - 3, 9, 6, body, 4)

        // Shoulder moss carpet.
        let cap = (x: 2.0, y: 20.0 + drop)
        art.rect(cap.x, cap.y, 42, 11, mossMid, 6)
        art.rect(cap.x + 4, cap.y + 1, 10, 7, mossLit, 4)
        art.rect(cap.x + 18, cap.y - 1, 12, 8, mossDeep, 5)
        art.rect(cap.x + 30, cap.y + 2, 9, 7, mossLit, 4)
        art.rect(cap.x + 5, cap.y + 6, 7, 6, mossMid, 3.5)
        art.rect(cap.x + 29, cap.y + 6, 9, 8, mossDeep, 4)

        // Sprig and flower.
        art.rect(8, 12 + drop, 1.5, 8, mossDeep, 0.8)
        art.rect(4.5, 12 + drop, 5, 3.5, mossLit, 1.8)
        art.rect(8.5, 13.5 + drop, 4, 3, mossMid, 1.5)
        art.rect(36, 15 + drop, 4, 4, flower, 2)
        art.rect(37, 16 + drop, 2, 2, t.warning, 1)

        // Head, neck, crown moss, ports and mouth slot.
        let hx = 14.0 + tilt, hy = 1.0 + drop
        art.rect(hx + 6, hy + 17, 5, 8, body, 2)
        art.rect(hx, hy + 2, 17, 20, bodyDepth, 8.5)
        art.panel(hx, hy, 17, 20, body, outline, 8.5, 1)
        art.rect(hx - 3, hy - 2, 19, 8, mossMid, 4)
        art.rect(hx - 1, hy - 1, 7, 5, mossLit, 2.5)
        art.rect(hx + 11, hy + 1, 6, 7, mossDeep, 3)

        let eyeY = hy + 6
        let gaze = pose == .approval ? 1.5 : 0
        for eyeX in [hx + 3, hx + 9] {
            if pose == .paused {
                art.rect(eyeX, eyeY + 2, 5.5, 2, pausedLid, 1)
            } else {
                art.panel(eyeX, eyeY, 5.5, 5.5, port, portRing, 2.75, 1)
                art.rect(eyeX + 1.8 + gaze, eyeY + 1.8, 2, 2, pupil, 1)
            }
        }
        art.rect(hx + 6, hy + 14.5, 5, 2, seam, 1)
    }

    // MARK: Vireo

    private func drawVireo(_ art: ArtContext, _ t: CharacterTheme) {
        let panel = t.background.mix(t.panelMuted, 0.42)
        let olive = t.accent.mix(t.warning, 0.45)
        let back = olive.mix(panel, 0.42)
        let breast = t.poleLight.mix(t.accent, 0.12)
        var outline = t.border.mix(t.accent, 0.35)
        if outline.distance(back) < 0.10 {
            outline = t.border
            if outline.distance(back) < 0.10 { outline = t.subtle }
        }
        let wing = olive.mix(panel, 0.40)
        let wingtip = olive.mix(t.panelMuted, 0.65)
        let tailColor = olive.mix(panel, 0.48)
        let headColor = back.mix(panel, 0.18)
        let crown = t.panelMuted.mix(t.poleDark, 0.26)
        let brow = t.poleLight.mix(t.accent, 0.20)
        let eyeline = t.poleDark.mix(t.warning, 0.28)
        let eyeColor = t.danger.mix(t.poleLight, 0.12)
        let pupil = t.background.mix(t.poleDark, 0.35)
        let beak = t.poleDark.mix(t.panelMuted, 0.22)
        let leg = t.panelMuted.mix(t.poleDark, 0.30)
        let pausedLid = t.background.mix(t.poleDark, 0.35).mix(t.danger, 0.30)
        let tilt = pose == .approval ? 1.4 : 0
        let drop = pose == .paused ? 2.0 : 0

        // Tail, body, legs and wing.
        art.rect(-9, 23 + drop, 21, 5, tailColor, 2.5)
        let body = (x: 5.0, y: 17.0, w: 33.0, h: 18.0)
        art.rect(body.x, body.y + 2, body.w, body.h, outline.alpha(40), 9)
        art.panel(body.x, body.y, body.w, body.h, back, outline, 9, 1)
        art.rect(body.x + 10, body.y + 8, 20, 9, breast, 5)
        art.rect(body.x + 13, body.y + body.h - 1, 1.8, 8, leg, 0.9)
        art.rect(body.x + body.w - 13.8, body.y + body.h - 1, 1.8, 8, leg, 0.9)
        art.rect(body.x + 1, body.y + 2.5, 21, 10, wing, 5)
        art.rect(body.x - 1, body.y + 7.5, 10, 4.5, wingtip, 2.2)

        // Profile head: crown, arched brow, eye-line, eye and beak.
        let hx = 22.0 + tilt, hy = 1.0 + drop
        art.panel(hx, hy, 24, 16, headColor, outline, 7, 1)
        art.rect(hx + 2, hy, 18, 6, crown, 4)
        art.arc([(hx + 5.5, hy + 5.8), (hx + 10.2, hy + 3.6), (hx + 16, hy + 3.3), (hx + 22.5, hy + 4.9)], 1.55, brow)
        art.arc([(hx + 6, hy + 7.2), (hx + 10.6, hy + 5.4), (hx + 16.2, hy + 5.2), (hx + 21.8, hy + 6.6)], 1.15, eyeline)
        let eyeX = hx + 14.5, eyeY = hy + 6.7
        if pose == .paused {
            art.rect(eyeX, eyeY, 5.5, 2.5, pausedLid, 1.2)
        } else {
            art.panel(eyeX, eyeY, 5.5, 5.5, eyeColor, brow, 2.75, 1)
            let offset = pose == .approval ? (x: 0.55 + 0.85, y: 1.55 + 0.45) : (x: 0.55, y: 1.55)
            art.rect(eyeX + offset.x, eyeY + offset.y, 2.2, 2.2, pupil, 1.1)
        }
        art.rect(hx + 24 - 3, hy + 7, 10, 3, beak, 1.5)
    }

    private func drawFailureBadge(_ art: ArtContext, _ t: CharacterTheme) {
        art.rect(-4, -2, 11, 11, t.charSurface, 5.5)
        art.rect(-2, 0, 7, 7, t.danger, 3.5)
    }
}

/// Desktop draw primitives over a SwiftUI `GraphicsContext`, in design units.
private struct ArtContext {
    var context: GraphicsContext
    let s: Double
    let origin: CGPoint

    private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: origin.x + x * s, y: origin.y + y * s, width: max(0, w * s), height: max(0, h * s))
    }
    private func point(_ p: (Double, Double)) -> CGPoint { CGPoint(x: origin.x + p.0 * s, y: origin.y + p.1 * s) }
    private func rounded(_ rect: CGRect, _ radius: Double) -> Path {
        Path(roundedRect: rect, cornerRadius: min(radius * s, min(rect.width, rect.height) / 2), style: .continuous)
    }

    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ fill: ArtColor, _ radius: Double) {
        context.fill(rounded(box(x, y, w, h), radius), with: .color(fill.color))
    }

    /// Stroke as a filled underlay with the fill inset by the stroke width (desktop `appendPanel`).
    func panel(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ fill: ArtColor, _ stroke: ArtColor, _ radius: Double, _ width: Double) {
        rect(x, y, w, h, stroke, radius)
        rect(x + width, y + width, w - 2 * width, h - 2 * width, fill, max(0, radius - width))
    }

    func clippedRect(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ fill: ArtColor, _ radius: Double,
                     clip: (Double, Double, Double, Double, Double)) {
        var layer = context
        layer.clip(to: rounded(box(clip.0, clip.1, clip.2, clip.3), clip.4))
        layer.fill(rounded(box(x, y, w, h), radius), with: .color(fill.color))
    }

    func triangle(_ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double), _ fill: ArtColor) {
        var path = Path()
        path.move(to: point(a)); path.addLine(to: point(b)); path.addLine(to: point(c)); path.closeSubpath()
        context.fill(path, with: .color(fill.color))
    }

    func line(_ from: (Double, Double), _ to: (Double, Double), _ width: Double, _ fill: ArtColor) {
        let dx = to.0 - from.0, dy = to.1 - from.1
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return }
        let nx = -dy / length * width * 0.5, ny = dx / length * width * 0.5
        triangle((from.0 + nx, from.1 + ny), (to.0 + nx, to.1 + ny), (to.0 - nx, to.1 - ny), fill)
        triangle((from.0 + nx, from.1 + ny), (to.0 - nx, to.1 - ny), (from.0 - nx, from.1 - ny), fill)
    }

    /// Three-segment ridge with soft round end caps (desktop `queueVireoArc`).
    func arc(_ points: [(Double, Double)], _ width: Double, _ fill: ArtColor) {
        for index in 0..<(points.count - 1) { line(points[index], points[index + 1], width, fill) }
        let cap = width * 0.55
        for tip in [points[0], points[points.count - 1]] { rect(tip.0 - cap, tip.1 - cap, cap * 2, cap * 2, fill, cap) }
    }
}
