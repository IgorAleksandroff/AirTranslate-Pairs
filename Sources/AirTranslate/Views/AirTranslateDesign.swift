import SwiftUI

enum AirTranslateDesign {
    static let sidebarMinimum: CGFloat = 260
    static let sidebarIdeal: CGFloat = 280
    static let sidebarMaximum: CGFloat = 300
    static let workspacePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 8
    static let controlRadius: CGFloat = 6
    static let surfaceRadius: CGFloat = 10
    static let iconSmall: CGFloat = 13
    static let iconRegular: CGFloat = 16
    static let iconLarge: CGFloat = 20
    static let separator = Color(nsColor: .separatorColor)
    static let quietFill = Color.primary.opacity(0.035)
    static let selectedFill = Color.accentColor.opacity(0.11)
}

private struct AirTranslateSurfaceModifier: ViewModifier {
    let isEmphasized: Bool

    func body(content: Content) -> some View {
        content
            .background(
                isEmphasized ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025),
                in: RoundedRectangle(cornerRadius: AirTranslateDesign.surfaceRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AirTranslateDesign.surfaceRadius, style: .continuous)
                    .strokeBorder(AirTranslateDesign.separator.opacity(0.55))
            }
    }
}

extension View {
    func airTranslateSurface(isEmphasized: Bool = false) -> some View {
        modifier(AirTranslateSurfaceModifier(isEmphasized: isEmphasized))
    }

    func airTranslateInteractiveSurface(
        isSelected: Bool = false,
        tint: Color = .accentColor
    ) -> some View {
        modifier(AirTranslateInteractiveSurfaceModifier(isSelected: isSelected, tint: tint))
    }
}

private struct AirTranslateInteractiveSurfaceModifier: ViewModifier {
    let isSelected: Bool
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                backgroundColor,
                in: RoundedRectangle(cornerRadius: AirTranslateDesign.controlRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AirTranslateDesign.controlRadius, style: .continuous)
                    .strokeBorder(borderColor)
            }
            .onHover { isHovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isHovering)
    }

    private var backgroundColor: Color {
        if isSelected {
            return tint.opacity(0.11)
        }
        return isHovering ? Color.primary.opacity(0.065) : Color.clear
    }

    private var borderColor: Color {
        if isSelected {
            return tint.opacity(0.30)
        }
        return isHovering ? AirTranslateDesign.separator.opacity(0.65) : .clear
    }
}

struct AirTranslatePressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(reduceMotion ? 1 : (configuration.isPressed ? 0.985 : 1))
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
