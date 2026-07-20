import AppKit
import SwiftUI

struct AppearanceSettings: View {
    @ObservedObject var appearance: AppearanceStore
    @ObservedObject var behavior: BehaviorStore
    @ObservedObject private var themes = ThemeStore.shared
    @StateObject private var apps = AppListModel()

    private var metrics: Metrics { appearance.metrics }
    private static let customLabel = "Custom…"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    themeBar
                    Divider()

                    SliderRow(
                        title: "Icon size",
                        help: "Window mode uses a smaller icon, and scales in step.",
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

                    Divider()

                    HStack {
                        Text("Highlight colour").font(.system(size: 12, weight: .medium))
                        Spacer()
                        ColorPicker("", selection: $behavior.highlightColor, supportsOpacity: false)
                            .labelsHidden()
                    }
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
                    HStack {
                        Text("Opacity").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Slider(value: $behavior.panelOpacity, in: 0.3...1.0).frame(width: 160)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Toggle("Custom blur", isOn: $behavior.blurOverride)
                                .toggleStyle(.checkbox)
                            Spacer()
                            Slider(value: $behavior.blurRadius, in: 0...50)
                                .frame(width: 160)
                                .disabled(!behavior.blurOverride)
                        }
                        Text("Override the material's built-in glass blur. 0 = none, 50 = heavy.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Max columns").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Stepper(
                            behavior.maxColumns == 0 ? "Auto" : "\(behavior.maxColumns)",
                            value: $behavior.maxColumns, in: 0...20)
                    }

                    HStack {
                        Text("Corner radius").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Slider(value: $behavior.tileCorner, in: 0...24, step: 1).frame(width: 160)
                    }
                    HStack {
                        Text("Title size").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Slider(value: $behavior.titleFontSize, in: 8...16, step: 1).frame(width: 160)
                    }
                    Toggle("Show number badges", isOn: $behavior.showNumbers)
                        .toggleStyle(.checkbox)
                    Toggle("Always show titles under icons", isOn: $behavior.alwaysShowTitles)
                        .toggleStyle(.checkbox)
                        .help("Show each tile's name in app mode too, not just the selected one.")
                    Toggle("Preview windows on hover", isOn: $behavior.windowPreview)
                        .toggleStyle(.checkbox)
                        .help(
                            "App mode: hover a tile to float live thumbnails of that app's windows. "
                                + "Needs Screen Recording permission.")
                        .onChange(of: behavior.windowPreview) {
                            if behavior.windowPreview { Permissions.ensureScreenCaptureForPreview() }
                        }
                    Toggle("Fade the panel in and out", isOn: $behavior.fade)
                        .toggleStyle(.checkbox)
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
                    .font(.system(size: 13, weight: .semibold))
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
        HStack {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .frame(width: 160)
        }
    }
}

private struct SliderRow: View {
    let title: String
    let help: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(value)) pt")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            Text(help).font(.system(size: 10)).foregroundStyle(.secondary)
        }
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

