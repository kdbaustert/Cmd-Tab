import AppKit
import SwiftUI

struct AppearanceSettings: View {
    @ObservedObject var appearance: AppearanceStore
    @ObservedObject var behavior: BehaviorStore
    @ObservedObject private var themes = ThemeStore.shared
    @StateObject private var apps = AppListModel()

    private var metrics: Metrics { appearance.metrics }
    private static let customLabel = "Custom…"

    /// Fixed rather than adaptive, so controls stay aligned down the pane instead of reflowing
    /// around whichever label happens to be longest.
    private static let twoColumns = [
        GridItem(.flexible(), spacing: 18, alignment: .leading),
        GridItem(.flexible(), spacing: 18, alignment: .leading),
    ]

    /// Installed families, resolved once. `availableFontFamilies` walks the font registry, which is
    /// slow enough to be worth keeping out of a view body that re-evaluates on every slider drag.
    /// Families that can't be resolved by name are dropped here rather than offered and then
    /// silently substituted at render time.
    private static let fontFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { NSFont(name: $0, size: 12) != nil }
        .sorted()

    /// Panel translucency. Separate from `SliderRow` because it is a fraction, not a point size.
    private var opacityRow: some View {
        HStack(spacing: 8) {
            Text("Opacity")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 86, alignment: .leading)
            Slider(value: $behavior.panelOpacity, in: 0.3...1.0)
            Text("\(Int(behavior.panelOpacity * 100))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
        .help("How much of the desktop shows through the panel.")
    }

    /// A label paired with any single control, matching the picker rows' shape.
    private func labelledRow(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 4)
            control()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
            Divider()

            ScrollView {
                // Paired into two columns throughout, and the per-control explanations moved to
                // tooltips. Each slider used to occupy three stacked lines (label, track, prose) —
                // with a dozen controls that pushed most of the pane below the fold for the sake of
                // text you read once. The window is wide enough now to carry two of everything.
                VStack(alignment: .leading, spacing: 10) {
                    themeBar
                    Divider()

                    LazyVGrid(columns: Self.twoColumns, alignment: .leading, spacing: 8) {
                        SliderRow(
                            title: "Icon size",
                            help: "Window tiles in the same-app cycle use a smaller icon, and scale in step.",
                            value: $appearance.iconSize,
                            range: Metrics.iconSizeRange,
                            step: 8)
                        SliderRow(
                            title: "Icon spacing",
                            help: "Slack around each icon, inside its highlight.",
                            value: $appearance.iconSpacing,
                            range: Metrics.iconSpacingRange,
                            step: 2)
                        SliderRow(
                            title: "Title spacing",
                            help: "Gap between an icon and its name.",
                            value: $appearance.titleSpacing,
                            range: Metrics.titleSpacingRange,
                            step: 1)
                        SliderRow(
                            title: "Corner radius",
                            help: "Roundness of the selected tile's highlight.",
                            value: $behavior.tileCorner,
                            range: 0...24,
                            step: 1)
                        SliderRow(
                            title: "Title size",
                            help: "Point size of tile titles and the caption.",
                            value: $behavior.titleFontSize,
                            range: 8...16,
                            step: 1)
                        opacityRow
                    }

                    Divider()

                    LazyVGrid(columns: Self.twoColumns, alignment: .leading, spacing: 8) {
                        pickerRow("Appearance", selection: $behavior.panelAppearance) {
                            ForEach(PanelAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        pickerRow("Position", selection: $behavior.panelPosition) {
                            ForEach(PanelPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        pickerRow("Show on", selection: $behavior.panelScreens) {
                            ForEach(PanelScreens.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        pickerRow("Material", selection: $behavior.panelMaterial) {
                            ForEach(PanelMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        labelledRow("Highlight") {
                            ColorPicker("", selection: $behavior.highlightColor, supportsOpacity: false)
                                .labelsHidden()
                        }
                        pickerRow("Title font", selection: $behavior.titleFontName) {
                            Text("System").tag("")
                            Divider()
                            ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
                        }
                        labelledRow("Max columns") {
                            Stepper(
                                behavior.maxColumns == 0 ? "Auto" : "\(behavior.maxColumns)",
                                value: $behavior.maxColumns, in: 0...20)
                        }
                    }

                    Divider()

                    // Full width: the checkbox gates the slider, so they have to read as one control.
                    HStack(spacing: 8) {
                        Toggle("Custom blur", isOn: $behavior.blurOverride)
                            .toggleStyle(.checkbox)
                            .frame(width: 110, alignment: .leading)
                        Slider(value: $behavior.blurRadius, in: 0...50)
                            .disabled(!behavior.blurOverride)
                        Text("\(Int(behavior.blurRadius))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                    }
                    .help("Override the material's built-in glass blur. 0 = none, 50 = heavy.")

                    Divider()

                    LazyVGrid(columns: Self.twoColumns, alignment: .leading, spacing: 4) {
                        Toggle("Number badges", isOn: $behavior.showNumbers)
                            .toggleStyle(.checkbox)
                            .help("The ⌘-number jump hint on the first nine tiles.")
                        Toggle("Notification badges", isOn: $behavior.notificationBadges)
                            .toggleStyle(.checkbox)
                            .help(
                                "Unread counts from each app's Dock icon. Read from the Dock over "
                                    + "Accessibility, so it is best-effort.")
                        Toggle("Display & Space badges", isOn: $behavior.showBadges)
                            .toggleStyle(.checkbox)
                            .help(
                                "Which display and Desktop a window is on, shown on window tiles in "
                                    + "the same-app cycle. Only ever appear when you have more than "
                                    + "one of either.")
                        Toggle("Preview windows on hover", isOn: $behavior.windowPreview)
                            .toggleStyle(.checkbox)
                            .help(
                                "App mode: hover a tile to float live thumbnails of that app's "
                                    + "windows. Needs Screen Recording permission.")
                            .onChange(of: behavior.windowPreview) {
                                if behavior.windowPreview {
                                    Permissions.ensureScreenCaptureForPreview()
                                }
                            }
                        Toggle("Fade in and out", isOn: $behavior.fade)
                            .toggleStyle(.checkbox)
                    }
                }
                .padding(12)
            }

            Divider()
            HStack {
                Text("Changes apply live, including to an open switcher.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset", action: appearance.reset)
                    .disabled(appearance.isDefault)
            }
            .padding(12)
        }
    }

    /// A real panel: same glass, same metrics, real icons. The switcher itself cannot be seen
    /// while the settings window is frontmost, so this has to stand in for it faithfully.
    private var preview: some View {
        let tile = metrics.tile(for: .apps)
        let entries = Array(apps.entries.prefix(4))
        return ScrollView([.horizontal, .vertical], showsIndicators: false) {
            VStack(spacing: metrics.titleSpacing) {
                HStack(spacing: Metrics.tileGap) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                        PreviewTile(
                            icon: entry.icon,
                            tile: tile,
                            iconSize: metrics.iconSize,
                            isSelected: i == min(1, entries.count - 1),
                            highlightColor: behavior.highlightColor)
                    }
                }
                Text(entries.count > 1 ? entries[1].name : "Preview")
                    // Tracks the real caption: same resolver, same size offset, so choosing a font
                    // or dragging the size slider shows here exactly what the switcher will do.
                    .font(TitleFont.resolve(behavior.titleFontName, size: behavior.titleFontSize + 3))
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .padding(Metrics.panelPadding)
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .fixedSize()
            .padding(14)
            .frame(maxWidth: .infinity)
        }
        // Fixed, so the window does not jump around as the sliders move.
        .frame(height: 210)
        .background(Color.primary.opacity(0.04))
    }

    /// Theme picker plus save/rename/delete/share. The picker reflects the current look: it shows
    /// the matching theme, or "Custom…" once the user has tuned away from every saved one.
    private var themeBar: some View {
        let selection = Binding<String>(
            get: { themes.currentMatch()?.name ?? Self.customLabel },
            set: { name in
                if let theme = themes.all.first(where: { $0.name == name }) { themes.apply(theme) }
            })
        let match = themes.currentMatch()
        let isCustomEditable = match != nil && !(match?.builtIn ?? true)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Theme").font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("", selection: selection) {
                    ForEach(themes.all) { Text($0.name).tag($0.name) }
                    if match == nil { Text(Self.customLabel).tag(Self.customLabel) }
                }
                .labelsHidden()
                .frame(width: 220)
            }
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

    /// A labelled dropdown row matching the slider rows' caption style.
    @ViewBuilder
    private func pickerRow<T: Hashable>(
        _ title: String, selection: Binding<T>, @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 4)
            Picker("", selection: selection, content: content)
                .labelsHidden()
                // Narrower than before: these now sit two to a row, so 160 crowded the label out.
                .frame(width: 130)
        }
    }
}

/// Label, track and value on one line, with the explanation as a tooltip.
///
/// The prose used to sit under every slider. It is worth reading once and then costs a line forever,
/// which is most of why this pane needed scrolling — so it moved to `.help`, where it is still there
/// on hover for anyone who wants it.
private struct SliderRow<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    let title: String
    let help: String
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V.Stride

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 86, alignment: .leading)
            Slider(value: $value, in: range, step: step)
            Text("\(Int(Double(value)))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
        .help(help)
    }
}

private struct PreviewTile: View {
    let icon: NSImage?
    let tile: CGSize
    let iconSize: CGFloat
    let isSelected: Bool
    let highlightColor: Color

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: iconSize, height: iconSize)
        .frame(width: tile.width, height: tile.height)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(highlightColor.opacity(isSelected ? 0.30 : 0))
        }
    }
}

