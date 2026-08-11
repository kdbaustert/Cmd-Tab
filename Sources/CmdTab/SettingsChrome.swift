import AppKit
import SwiftUI

// The settings window's visual vocabulary, in the shape macOS System Settings uses: a sidebar of
// tabs with gradient icon badges, and content built from titled sections whose rows sit inside a
// rounded card. Every pane is assembled from the pieces in this file, so the panes themselves
// describe *what* they offer rather than how it is drawn.

// MARK: - Palette

enum SettingsChrome {
    /// Every piece of user-facing text in the settings window goes through here.
    ///
    /// The obvious way to localise SwiftUI is to type the parameters `LocalizedStringKey`, which
    /// makes string literals at the call sites localisable for free. It does not work for this
    /// codebase: the long explanations under each row are assembled with `+` across several source
    /// lines to keep them inside the line limit, and a concatenation is not a literal, so nine out
    /// of ten subtitles here would silently stop being localisable the moment they were wrapped.
    ///
    /// Looking the finished string up at the point of display handles both, and does it in one
    /// place rather than at four hundred call sites. A key that is not in the catalogue renders as
    /// itself, which is exactly the English text that was passed in.
    static func text(_ string: String) -> Text {
        Text(LocalizedStringKey(string))
    }

    /// For text that is *data* rather than interface — an app's name, a shortcut's description, a
    /// version number. Looking those up would mean an app called "General" could be translated into
    /// whatever the sidebar's General tab is called.
    static func verbatim(_ string: String) -> Text {
        Text(verbatim: string)
    }

    static let cardCorner: CGFloat = 14
    static let hairline: CGFloat = 0.5

    /// Card fill and border. `.primary` rather than fixed light/dark values so both follow the
    /// window's appearance without a second code path.
    ///
    /// Pitched a little heavier than a card on an opaque window would be: these sit on glass, and a
    /// 3% fill over a backdrop that is itself showing the desktop through it does not read as a
    /// card at all — it reads as nothing.
    static let cardFill = Color.primary.opacity(0.05)
    static let cardBorder = Color.primary.opacity(0.09)

    /// Divider between rows, inset to line up with the row's text rather than running wall to wall.
    static let divider = Color.primary.opacity(0.07)

    /// Horizontal inset shared by section headers and row content, so a header sits over its
    /// column rather than floating between them.
    static let rowInset: CGFloat = 14
    static let pageInset: CGFloat = 18
}

// MARK: - Flash (search result → the row it landed on)

private struct SettingsFlashKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    /// Anchor of the section a search result just navigated to. That section outlines itself for a
    /// moment, which is the only thing that tells the user *which* of the rows they were sent to.
    var settingsFlash: String? {
        get { self[SettingsFlashKey.self] }
        set { self[SettingsFlashKey.self] = newValue }
    }
}

// MARK: - Page

/// A settings tab's content: a scrolling column of sections under the tab's own title.
struct SettingsPage<Content: View>: View {
    let title: String
    /// One line under the title. The place for context that applies to the whole tab, which would
    /// otherwise be repeated across half its rows.
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                VStack(alignment: .leading, spacing: 3) {
                    SettingsChrome.text(title).font(.system(size: 21, weight: .bold))
                    if let subtitle {
                        SettingsChrome.text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 2)

                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SettingsChrome.pageInset)
            .padding(.top, 15)
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Section

/// A titled group of rows inside a rounded card.
///
/// Rows draw their own top divider (see `SettingsRow`), so a section takes any number of them in
/// any order without having to be told which one is last. The first row's divider lands exactly on
/// the card's top edge, where the border stroke covers it.
struct SettingsSection<Content: View>: View {
    let title: String
    /// Identifier the search index scrolls to, and the one `settingsFlash` names.
    var anchor: String?
    /// Explanatory text under the card, for anything too long to hang off a single row.
    var footer: String?
    @ViewBuilder let content: Content

    @Environment(\.settingsFlash) private var flash

    private var isFlashing: Bool { anchor != nil && anchor == flash }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SettingsChrome.text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 2)

            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous)
                        .fill(SettingsChrome.cardFill))
                .clipShape(
                    RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous)
                        .strokeBorder(
                            isFlashing ? Color.accentColor : SettingsChrome.cardBorder,
                            lineWidth: isFlashing ? 2 : SettingsChrome.hairline))
                .animation(.easeInOut(duration: 0.25), value: isFlashing)

            if let footer {
                SettingsChrome.text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
        .id(anchor ?? title)
    }
}

// MARK: - Rows

/// Label and optional explanation on the left, control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    /// Set for a row whose title is *data* rather than interface — the per-app rows, whose titles
    /// are the names of the user's applications. Without it an app called "General" would be looked
    /// up in the catalogue and could come back as the sidebar's General tab.
    ///
    /// Declared after `subtitle` because Swift's memberwise initialiser fixes argument order, and
    /// the call sites that need it also pass a subtitle.
    var isTitleVerbatim = false
    /// Lets a row give its control more of the width — sliders and recorders need it, a checkbox
    /// does not.
    var controlWidth: CGFloat?
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                (isTitleVerbatim ? SettingsChrome.verbatim(title) : SettingsChrome.text(title))
                    .font(.system(size: 13))
                if let subtitle {
                    SettingsChrome.text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
                .frame(width: controlWidth, alignment: .trailing)
                // The row's whole shape is a label on the left and a control on the right, which
                // reads correctly and announces as nothing: every control here is built with
                // `labelsHidden()` so the checkboxes line up down the card's edge, and a hidden
                // label is hidden from VoiceOver too. Sighted users get the association from the
                // layout; this is the same association stated to the accessibility tree.
                //
                // Applied here rather than at each control so it cannot be forgotten by the next
                // row someone adds. Harmless on the rows whose control is a container of several
                // already-labelled things — a label on a non-element is ignored.
                .accessibilityLabel(
                    isTitleVerbatim ? SettingsChrome.verbatim(title) : SettingsChrome.text(title))
                .accessibilityHint(SettingsChrome.text(subtitle ?? ""))
        }
        .padding(.horizontal, SettingsChrome.rowInset)
        .padding(.vertical, 9)
        .frame(minHeight: 38)
        .settingsRowDivider()
    }
}

/// A row that is one full-width control rather than a label/control pair — a segmented picker, a
/// button bar, a list of apps.
struct SettingsWideRow<Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || subtitle != nil {
                VStack(alignment: .leading, spacing: 2) {
                    if let title { SettingsChrome.text(title).font(.system(size: 13)) }
                    if let subtitle {
                        SettingsChrome.text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsChrome.rowInset)
        .padding(.vertical, 11)
        .settingsRowDivider()
    }
}

extension View {
    /// The hairline above a row. Drawn on every row rather than every row but the first: the first
    /// one lands on the card's own top edge, under the border stroke, so it costs nothing.
    fileprivate func settingsRowDivider() -> some View {
        overlay(alignment: .top) {
            Rectangle()
                .fill(SettingsChrome.divider)
                .frame(height: SettingsChrome.hairline)
        }
    }
}

// MARK: - Common controls

/// A checkbox row. The title carries the checkbox's own label, so the control column stays empty
/// and every toggle in a card lines up down the right-hand edge.
struct SettingsToggle: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// A slider with its value beside it. The number matters — several of these are pixel sizes someone
/// wants to set exactly, not by feel.
struct SettingsSlider<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    let title: String
    var subtitle: String?
    @Binding var value: V
    let range: ClosedRange<V>
    var step: V.Stride = 1
    /// Shown in place of the number, for sliders whose units are not pixels — a bare number is read
    /// as px, so anything else (milliseconds, an "Off" at zero) has to say so itself.
    var format: ((V) -> String)?

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, controlWidth: 190) {
            HStack(spacing: 8) {
                Slider(value: stepped, in: range)
                Text(format?(value) ?? "\(Int(Double(value)))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
                    // The number is the slider's value rendered beside it, not a second thing on
                    // the row. Read as its own element it announces a bare "18" after the slider
                    // has already said the same.
                    .accessibilityHidden(true)
            }
            // Spoken rather than the raw fraction: several of these are pixel sizes, and "40
            // percent" is not what the setting is measured in. `format` is what the row shows
            // sighted users for exactly the same reason.
            .accessibilityValue(format?(value) ?? "\(Int(Double(value)))")
        }
    }

    /// The value snapped to `step` on the way in, rather than by handing `step` to the `Slider`.
    ///
    /// Same stepping, no tick marks. AppKit draws a tick for every step beneath a slider built with
    /// the stepping initialiser, so a 0–100 gap in twos arrived as fifty dots under the track — and
    /// what they were there for is already spelled out in the number beside it.
    private var stepped: Binding<V> {
        Binding(
            get: { value },
            set: { new in
                let size = V(step)
                guard size > 0 else {
                    value = new
                    return
                }
                // Clamped after rounding: the top of a range that is not a whole number of steps
                // would otherwise round past its own end.
                let snapped = (new / size).rounded() * size
                value = min(max(snapped, range.lowerBound), range.upperBound)
            })
    }
}

/// A dropdown row.
struct SettingsPicker<Value: Hashable, Content: View>: View {
    let title: String
    var subtitle: String?
    @Binding var selection: Value
    var width: CGFloat = 170
    @ViewBuilder let options: Content

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, controlWidth: width) {
            Picker("", selection: $selection, content: { options })
                .labelsHidden()
        }
    }
}

/// A choice presented as radio buttons with an explanation under each option, rather than as a
/// dropdown. For the handful of settings where the options are not self-explanatory and the user
/// should not have to open a menu to find out what they do — the switcher layout being the one this
/// was built for.
struct SettingsChoice<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let title: String
        var detail: String?
        var symbol: String?

        /// Keyed on the *value* rather than the title, which is now a `LocalizedStringKey` and has
        /// no accessible key to hash. Better identity anyway: the value is what the option means,
        /// and two options can no longer collide by being renamed to the same words.
        var id: Value { value }
    }

    let title: String
    var subtitle: String?
    @Binding var selection: Value
    let options: [Option]

    var body: some View {
        SettingsWideRow(title: title, subtitle: subtitle) {
            HStack(alignment: .top, spacing: 10) {
                ForEach(options) { option in
                    Button {
                        selection = option.value
                    } label: {
                        card(for: option)
                    }
                    .buttonStyle(.plain)
                    // These are radio buttons wearing a card, and without this they announce as
                    // plain buttons whose selected state is carried entirely by a filled-in circle
                    // and an accent colour — both invisible to VoiceOver. `.isSelected` is what
                    // makes the current choice audible.
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(option.title)
                    .accessibilityHint(SettingsChrome.text(option.detail ?? ""))
                    .accessibilityAddTraits(
                        option.value == selection ? [.isButton, .isSelected] : .isButton)
                }
            }
        }
    }

    private func card(for option: Option) -> some View {
        let isSelected = option.value == selection
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let symbol = option.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                Text(option.title)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            if let detail = option.detail {
                SettingsChrome.text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.06 : 0.02)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 1.5 : SettingsChrome.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Sidebar icon badge

/// A tab's icon in the sidebar: a white SF Symbol on a rounded gradient badge, the way System
/// Settings marks its own tabs.
struct SettingsTabIcon: View {
    let symbol: String
    let start: Color
    let end: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [start, end], startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay {
                // Falls back rather than trusting the name. An SF Symbol that does not resolve —
                // renamed in a later macOS, or simply mistyped — renders as *nothing*, leaving a
                // blank badge with no hint as to why.
                Image(systemName: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil
                    ? symbol : "questionmark")
                    .font(.system(size: size * 0.55, weight: .medium))
                    .foregroundStyle(.white)
            }
    }
}

/// A search field styled to sit in the sidebar.
struct SettingsSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.07)))
    }
}
