import SwiftUI
import UIKit

/// Semantic names from docs/workspace-switcher-sidebar.md; the core projects the index.
let workspaceIconNames = ["folder", "rocket", "flask", "leaf", "bolt", "star", "flame", "cube",
                          "code", "terminal", "globe", "heart", "moon", "sun", "compass", "puzzle"]

/// Closest iOS 17 SF Symbols (there is no rocket symbol; paperplane stands in).
private let workspaceSymbols = ["folder.fill", "paperplane.fill", "flask.fill", "leaf.fill", "bolt.fill", "star.fill",
                                "flame.fill", "cube.fill", "chevron.left.forwardslash.chevron.right", "terminal.fill",
                                "globe", "heart.fill", "moon.fill", "sun.max.fill", "safari.fill", "puzzlepiece.fill"]

func workspaceSymbol(_ index: Int) -> String {
    workspaceSymbols[((index % workspaceSymbols.count) + workspaceSymbols.count) % workspaceSymbols.count]
}

/// Spec color slot: accent hue rotated by `slot * 45°`, saturation clamped to [0.45, 0.85],
/// lightness to [0.55, 0.72] on dark and [0.38, 0.50] on light appearances.
func workspaceRGB(slot: Int, accent: (r: Double, g: Double, b: Double), dark: Bool) -> (r: Double, g: Double, b: Double) {
    let (r, g, b) = accent
    let maxV = max(r, g, b), minV = min(r, g, b), d = maxV - minV
    let l = (maxV + minV) / 2
    let s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
    var h: Double = 0
    if d != 0 {
        if maxV == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if maxV == g { h = 60 * ((b - r) / d + 2) }
        else { h = 60 * ((r - g) / d + 4) }
    }
    let k = ((slot % 8) + 8) % 8
    var hue = (h + Double(k) * 45).truncatingRemainder(dividingBy: 360)
    if hue < 0 { hue += 360 }
    let sat = min(max(s, 0.45), 0.85)
    let light = dark ? min(max(l, 0.55), 0.72) : min(max(l, 0.38), 0.50)
    // HSL -> RGB.
    let c = (1 - abs(2 * light - 1)) * sat
    let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
    let m = light - c / 2
    var rgb: (Double, Double, Double)
    switch hue {
    case ..<60: rgb = (c, x, 0)
    case ..<120: rgb = (x, c, 0)
    case ..<180: rgb = (0, c, x)
    case ..<240: rgb = (0, x, c)
    case ..<300: rgb = (x, 0, c)
    default: rgb = (c, 0, x)
    }
    return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
}

/// Resolves against the current theme accent per trait collection, so host palettes and light mode apply.
func workspaceColor(_ slot: Int) -> Color {
    Color(uiColor: UIColor { traits in
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(VerdeTheme.accent).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        let out = workspaceRGB(slot: slot, accent: (Double(r), Double(g), Double(b)), dark: traits.userInterfaceStyle != .light)
        return UIColor(red: out.r, green: out.g, blue: out.b, alpha: 1)
    })
}

/// Identity icon on a square chip tinted with the slot color at 18% alpha.
struct WorkspaceChip: View {
    let workspace: Workspace
    var size: CGFloat = 18
    var body: some View {
        let color = workspaceColor(Int(workspace.color_index))
        Image(systemName: workspaceSymbol(Int(workspace.icon_index)))
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.18), in: RoundedRectangle(cornerRadius: size * 0.25))
            .accessibilityHidden(true)
    }
}
