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

/// Automatic (icon, color) slots for `id`: FNV-1a 32-bit over its UTF-8 bytes, icon `h % 16`,
/// color `(h >> 8) % 8`, as in client_core projection.zig. The core projects the effective
/// slots; this only previews "Automatic" while a pinned slot is being edited.
func workspaceAutoIdentity(_ id: String) -> (icon: Int, color: Int) {
    var h: UInt32 = 0x811C9DC5
    for b in id.utf8 { h = (h ^ UInt32(b)) &* 0x01000193 }
    return (Int(h % 16), Int((h >> 8) % 8))
}

/// Picks a pinned icon and color, or Automatic (nil) for either; Save sends one intent.
struct WorkspaceIdentitySheet: View {
    let workspace: Workspace
    let save: (Int?, Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var icon: Int?
    @State private var color: Int?

    init(workspace: Workspace, save: @escaping (Int?, Int?) -> Void) {
        self.workspace = workspace
        self.save = save
        _icon = State(initialValue: workspace.icon_custom ? Int(workspace.icon_index) : nil)
        _color = State(initialValue: workspace.color_custom ? Int(workspace.color_index) : nil)
    }

    var body: some View {
        let auto = workspaceAutoIdentity(workspace.workspace_id)
        let tint = workspaceColor(color ?? auto.color)
        let changed = icon != (workspace.icon_custom ? Int(workspace.icon_index) : nil)
            || color != (workspace.color_custom ? Int(workspace.color_index) : nil)
        NavigationStack {
            Form {
                Section("Icon") {
                    automatic(icon == nil) { icon = nil }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                        ForEach(0..<16, id: \.self) { k in
                            let shown = (icon ?? auto.icon) == k
                            Button { icon = k } label: {
                                Image(systemName: workspaceSymbol(k)).font(.system(size: 20, weight: .semibold)).foregroundStyle(tint)
                                    .frame(maxWidth: .infinity, minHeight: 48)
                                    .background(shown ? tint.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(icon == k ? tint : Color.clear, lineWidth: 2))
                            }.buttonStyle(.plain)
                                .accessibilityLabel(workspaceIconNames[k]).accessibilityAddTraits(icon == k ? .isSelected : [])
                                .accessibilityIdentifier("identity-icon-\(k)")
                        }
                    }.padding(.vertical, 6)
                }
                Section("Color") {
                    automatic(color == nil) { color = nil }
                    HStack(spacing: 6) {
                        ForEach(0..<8, id: \.self) { k in
                            Button { color = k } label: {
                                Circle().fill(workspaceColor(k)).padding(4)
                                    .overlay(Circle().stroke(color == k ? VerdeTheme.text : Color.clear, lineWidth: 2))
                                    .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                            }.buttonStyle(.plain)
                                .accessibilityLabel("Color \(k + 1)").accessibilityAddTraits(color == k ? .isSelected : [])
                                .accessibilityIdentifier("identity-color-\(k)")
                        }
                    }.padding(.vertical, 6)
                }
            }
            .navigationTitle("Icon and color").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(icon, color); dismiss() }.disabled(!changed) }
            }
        }
    }

    private func automatic(_ selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text("Automatic").foregroundStyle(VerdeTheme.text)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(VerdeTheme.accent) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
