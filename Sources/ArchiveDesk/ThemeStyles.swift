import SwiftUI

private struct MikuThemeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var mikuTheme: Bool {
        get { self[MikuThemeKey.self] }
        set { self[MikuThemeKey.self] = newValue }
    }
}

/// Darker teal on light surfaces; luminous mint on dark surfaces.
/// Content and error colors remain semantic, rather than tinting every label.
struct MikuPalette {
    let dark: Bool
    var accent: Color { dark ? Color(red: 0.40, green: 0.88, blue: 0.83) : Color(red: 0.00, green: 0.46, blue: 0.43) }
    var pink: Color { dark ? Color(red: 0.95, green: 0.56, blue: 0.73) : Color(red: 0.76, green: 0.13, blue: 0.39) }
}

private struct ArchiveThemeModifier: ViewModifier {
    let enabled: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let palette = MikuPalette(dark: scheme == .dark)
        if enabled {
            content.environment(\.mikuTheme, true)
                .tint(palette.accent).accentColor(palette.accent)
                .background {
                    Color(nsColor: .windowBackgroundColor)
                        .overlay {
                            if !reduceTransparency {
                                LinearGradient(colors: [palette.accent.opacity(0.10), .clear, palette.pink.opacity(0.045)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            }
                        }
                }
        } else {
            content.environment(\.mikuTheme, false)
        }
    }
}

private struct ArchiveGlassModifier: ViewModifier {
    @Environment(\.mikuTheme) private var miku
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var accent: Color { MikuPalette(dark: scheme == .dark).accent }
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay { border }
        } else if #available(macOS 26.0, *) {
            if miku {
                content.glassEffect(.regular.tint(accent.opacity(0.10)), in: .rect(cornerRadius: 14))
                    .overlay { border }
            } else {
                content.glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay { border }
        }
    }
    @ViewBuilder private var border: some View {
        if miku {
            RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.24), lineWidth: 1)
                .allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

extension View {
    func archiveTheme(miku: Bool) -> some View { modifier(ArchiveThemeModifier(enabled: miku)) }
    func archiveGlass() -> some View { modifier(ArchiveGlassModifier()) }
}

struct ArchiveThemePicker: View {
    @EnvironmentObject var model: Model
    @EnvironmentObject var language: AppLanguage
    var body: some View {
        Picker(language.text("Color theme"), selection: $model.colorTheme) {
            Text(language.text("Standard colors")).tag("standard")
            Text(language.text("Miku · Teal & Pink")).tag("miku")
        }
    }
}

struct MikuThemeBadge: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let palette = MikuPalette(dark: scheme == .dark)
        Label("MIKU", systemImage: "waveform").font(.caption.weight(.semibold))
            .foregroundStyle(palette.pink).padding(.horizontal, 8).padding(.vertical, 4)
            .background(palette.accent.opacity(0.10), in: Capsule())
            .accessibilityLabel("Miku")
    }
}
