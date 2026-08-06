import AppKit
import SwiftUI

struct AppearanceSettings: View {
    @ObservedObject var appearance: AppearanceStore
    @ObservedObject var behavior: BehaviorStore
    @ObservedObject private var themes = ThemeStore.shared
    @StateObject private var apps = AppListModel()

    private var metrics: Metrics { appearance.metrics }
    private static let customLabel = "Custom…"

    /// Installed families, resolved once. `availableFontFamilies` walks the font registry, which is
    /// slow enough to be worth keeping out of a view body that re-evaluates on every slider drag.
    /// Families that can't be resolved by name are dropped here rather than offered and then
    /// silently substituted at render time.
    private static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { NSFont(name: $0, size: 12) != nil }
        .sorted()

    var body: some View {
        SettingsPage(
            title: "Appearance",
            subtitle: "Changes apply live, including to a switcher that is already open."
        ) {
            preview

            SettingsSection(title: "Layout", anchor: SettingsAnchor.layout) {
                SettingsChoice(
                    title: "Layout",
                    subtitle: "The shape the switcher takes.",
                    selection: $behavior.layout,
                    options: SwitcherLayout.allCases.map {
                        .init(value: $0, title: $0.title, detail: $0.detail, symbol: $0.symbol)
                    })
                SettingsRow(
                    title: "Max columns",
                    subtitle: behavior.layout == .list
                        ? "How many columns of rows a long list may wrap into."
                        : "How many tiles a row may hold before the grid wraps."
                ) {
                    Stepper(
                        behavior.maxColumns == 0 ? "Auto" : "\(behavior.maxColumns)",
                        value: $behavior.maxColumns, in: 0...20)
                }
            }

            SettingsSection(
                title: "Theme", anchor: SettingsAnchor.theme,
                footer: "A theme carries only the look — never a shortcut — so importing one can "
                    + "not change what your keys do."
            ) {
                themeRow
            }

            SettingsSection(title: "Panel", anchor: SettingsAnchor.panel) {
                SettingsPicker(
                    title: "Appearance",
                    subtitle: "Force the panel light or dark regardless of the system setting.",
                    selection: $behavior.panelAppearance
                ) {
                    ForEach(PanelAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SettingsPicker(
                    title: "Material",
                    subtitle: "The frosted glass behind the tiles.",
                    selection: $behavior.panelMaterial
                ) {
                    ForEach(PanelMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                // The checkbox gates the slider, so they have to read as one control.
                SettingsRow(
                    title: "Custom blur",
                    subtitle: "Override the material's built-in glass blur. 0 = none, 50 = heavy.",
                    controlWidth: 230
                ) {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $behavior.blurOverride)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        Slider(value: $behavior.blurRadius, in: 0...50)
                            .disabled(!behavior.blurOverride)
                        Text("\(Int(behavior.blurRadius))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                    }
                }
                SettingsRow(
                    title: "Highlight",
                    subtitle: "Tint behind the selected tile."
                ) {
                    ColorPicker("", selection: $behavior.highlightColor, supportsOpacity: false)
                        .labelsHidden()
                }
            }

            SettingsSection(title: "Tiles", anchor: SettingsAnchor.tiles) {
                SettingsSlider(
                    title: "Icon size",
                    subtitle: "Scales the whole panel. Window tiles and list rows use a smaller "
                        + "icon, and follow in step.",
                    value: $appearance.iconSize,
                    range: Metrics.iconSizeRange,
                    step: 1)
                SettingsSlider(
                    title: "Icon spacing",
                    subtitle: "Slack around each icon, inside its highlight.",
                    value: $appearance.iconSpacing,
                    range: Metrics.iconSpacingRange,
                    step: 1)
                SettingsSlider(
                    title: "Title spacing",
                    subtitle: "Gap between an icon and its name.",
                    value: $appearance.titleSpacing,
                    range: Metrics.titleSpacingRange,
                    step: 1)
                SettingsSlider(
                    title: "Corner radius",
                    subtitle: "Roundness of the selected tile's highlight.",
                    value: $behavior.tileCorner,
                    range: 0...24,
                    step: 1)
            }

            SettingsSection(title: "Labels", anchor: SettingsAnchor.labels) {
                SettingsSlider(
                    title: "Title size",
                    subtitle: "Point size of tile titles and the caption.",
                    value: $behavior.titleFontSize,
                    range: 8...16,
                    step: 1)
                SettingsPicker(
                    title: "Title font", selection: $behavior.titleFontName, width: 190
                ) {
                    Text("System").tag("")
                    Divider()
                    ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
                }
            }

            SettingsSection(title: "Markers", anchor: SettingsAnchor.markers) {
                SettingsToggle(
                    title: "Number badges",
                    subtitle: "The ⌘-number jump hint on the first ten targets.",
                    isOn: $behavior.showNumbers)
                SettingsToggle(
                    title: "Notification badges",
                    subtitle: "Unread counts from each app's Dock icon. Read from the Dock over "
                        + "Accessibility, so it is best-effort.",
                    isOn: $behavior.notificationBadges)
                SettingsToggle(
                    title: "Display badges",
                    subtitle: "Which display a window is on. Only ever appears when more than one "
                        + "is connected.",
                    isOn: $behavior.showDisplayBadges)
                SettingsToggle(
                    title: "Space badges",
                    subtitle: "Which Desktop a window is on. Only ever appears when you have more "
                        + "than one.",
                    isOn: $behavior.showSpaceBadges)
                SettingsToggle(
                    title: "Fade in and out", isOn: $behavior.fade)
            }

            HStack {
                Spacer()
                Button("Reset sliders", action: appearance.reset)
                    .disabled(appearance.isDefault)
            }
        }
    }

    /// A real panel: same glass, same metrics, real icons, and the layout that is actually
    /// selected. The switcher itself cannot be seen while the settings window is frontmost, so this
    /// has to stand in for it faithfully.
    private var preview: some View {
        let entries = Array(apps.entries.prefix(4))
        let selected = min(1, max(entries.count - 1, 0))
        return VStack(spacing: 0) {
            Group {
                if behavior.layout == .list {
                    listPreview(entries, selected: selected)
                } else {
                    gridPreview(entries, selected: selected)
                }
            }
            .padding(Metrics.panelPadding)
            // The same glass the switcher builds in `SwitcherView.body`, driven from the same
            // settings — so the Material picker and the blur slider change something you can see.
            .background(
                VisualEffectBackground(
                    material: behavior.panelMaterial.nsMaterial,
                    blurRadius: behavior.blurOverride ? behavior.blurRadius : nil))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .fixedSize()
            .scaleEffect(previewScale, anchor: .center)
            .frame(maxWidth: .infinity)
        }
        // Fixed, so the window does not jump around as the sliders move.
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous)
                .fill(Color.primary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous))
    }

    /// Keeps a panel built from the largest icon size inside the preview strip rather than letting
    /// it overflow. Scaled rather than clipped or re-laid-out: the point of a preview is the
    /// proportions, and those survive a scale where a reflow would destroy them.
    private var previewScale: CGFloat {
        let size = previewPanelSize
        return min(1, min(500 / size.width, 168 / size.height))
    }

    /// What the four-target preview panel measures, ahead of drawing it.
    private var previewPanelSize: CGSize {
        let pad = Metrics.panelPadding * 2
        if behavior.layout == .list {
            let row = metrics.listRow(for: .apps)
            return CGSize(
                width: row.width + pad,
                height: row.height * 4 + Metrics.rowGap * 3 + pad)
        }
        let tile = metrics.tile(for: .apps)
        return CGSize(
            width: tile.width * 4 + Metrics.tileGap * 3 + pad,
            height: tile.height + metrics.titleSpacing + behavior.titleFontSize + 8 + pad)
    }

    private func gridPreview(_ entries: [AppEntry], selected: Int) -> some View {
        VStack(spacing: metrics.titleSpacing) {
            HStack(spacing: Metrics.tileGap) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                    PreviewTile(
                        icon: entry.icon,
                        tile: metrics.tile(for: .apps),
                        iconSize: metrics.iconSize,
                        isSelected: i == selected,
                        corner: behavior.tileCorner,
                        highlightColor: behavior.highlightColor)
                }
            }
            Text(entries.count > selected ? entries[selected].name : "Preview")
                // Tracks the real caption: same resolver, same size offset, so choosing a font or
                // dragging the size slider shows here exactly what the switcher will do.
                .font(TitleFont.resolve(behavior.titleFontName, size: behavior.titleFontSize + 3))
                .fontWeight(.semibold)
                .lineLimit(1)
        }
    }

    private func listPreview(_ entries: [AppEntry], selected: Int) -> some View {
        let row = metrics.listRow(for: .apps)
        return VStack(spacing: Metrics.rowGap) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                PreviewRow(
                    icon: entry.icon,
                    name: entry.name,
                    row: row,
                    iconSize: metrics.listIconSize,
                    isSelected: i == selected,
                    corner: behavior.tileCorner,
                    highlightColor: behavior.highlightColor,
                    font: TitleFont.resolve(
                        behavior.titleFontName, size: behavior.titleFontSize + 2))
            }
        }
    }

    /// Theme picker plus save/rename/delete/share. The picker reflects the current look: it shows
    /// the matching theme, or "Custom…" once the user has tuned away from every saved one.
    private var themeRow: some View {
        let selection = Binding<String>(
            get: { themes.currentMatch()?.name ?? Self.customLabel },
            set: { name in
                // `theme(named:)` rather than a scan of `all`: a custom theme may share a preset's
                // name, and picking it has to apply — and select — the user's own.
                if let theme = themes.theme(named: name) { themes.apply(theme) }
            })
        let match = themes.currentMatch()
        let isCustomEditable = match != nil && !(match?.builtIn ?? true)

        return Group {
            SettingsRow(title: "Theme", controlWidth: 200) {
                Picker("", selection: selection) {
                    ForEach(themes.all) { Text($0.name).tag($0.name) }
                    if match == nil { Text(Self.customLabel).tag(Self.customLabel) }
                }
                .labelsHidden()
            }
            SettingsWideRow {
                HStack(spacing: 6) {
                    Button("Save as…", action: saveTheme)
                    Button("Rename", action: renameTheme).disabled(!isCustomEditable)
                    Button("Delete", action: deleteTheme).disabled(!isCustomEditable)
                    Spacer()
                    Button("Import…") { themes.importTheme() }
                    Button("Export…", action: exportTheme).disabled(match == nil)
                }
                .controlSize(.small)
            }
        }
    }

    private func saveTheme() {
        guard let name = Self.promptName("Save theme as", default: "My Theme") else { return }
        themes.saveAs(name)
    }

    private func renameTheme() {
        guard let theme = themes.currentMatch(),
              let name = Self.promptName("Rename theme", default: theme.name) else { return }
        themes.rename(theme, to: name)
    }

    private func deleteTheme() {
        if let theme = themes.currentMatch() { themes.delete(theme) }
    }

    private func exportTheme() {
        if let theme = themes.currentMatch() { themes.export(theme) }
    }

    private static func promptName(_ title: String, default def: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = def
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct PreviewTile: View {
    let icon: NSImage?
    let tile: CGSize
    let iconSize: CGFloat
    let isSelected: Bool
    let corner: CGFloat
    let highlightColor: Color

    var body: some View {
        PreviewIcon(icon: icon, size: iconSize)
            .frame(width: tile.width, height: tile.height)
            .background { PreviewHighlight(corner: corner, color: highlightColor, on: isSelected) }
    }
}

private struct PreviewRow: View {
    let icon: NSImage?
    let name: String
    let row: CGSize
    let iconSize: CGFloat
    let isSelected: Bool
    let corner: CGFloat
    let highlightColor: Color
    let font: Font

    var body: some View {
        HStack(spacing: 8) {
            PreviewIcon(icon: icon, size: iconSize)
            Text(name)
                .font(font)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: row.width, height: row.height)
        .background {
            PreviewHighlight(
                corner: min(corner, row.height / 2), color: highlightColor, on: isSelected)
        }
    }
}

private struct PreviewIcon: View {
    let icon: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: size, height: size)
    }
}

/// Mirrors `TargetTile`'s selection treatment — see the reasoning there.
private struct PreviewHighlight: View {
    let corner: CGFloat
    let color: Color
    let on: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        shape
            .fill(color.opacity(on ? 0.30 : 0))
            .overlay { shape.strokeBorder(.primary.opacity(on ? 0.28 : 0), lineWidth: 1) }
    }
}
