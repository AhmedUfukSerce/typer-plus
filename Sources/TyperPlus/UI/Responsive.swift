import SwiftUI

// MARK: - Responsive breakpoints & layout metrics

enum Layout {
    /// Reading measure — clamp long text columns and center them on wide windows.
    static let contentMaxWidth: CGFloat = 760
    /// Home runs a touch wider than a pure reading column.
    static let homeMaxWidth: CGFloat = 1080
    /// Leading inset so the single-page top bar clears the window traffic lights.
    static let trafficLightInset: CGFloat = 84
}

/// Clamp a screen's content to a comfortable measure and center it, so text never
/// stretches edge-to-edge on a wide window. Apply to a screen's content container.
struct ContentWidthClamp: ViewModifier {
    var maxWidth: CGFloat = Layout.contentMaxWidth
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
extension View {
    func clampContentWidth(_ maxWidth: CGFloat = Layout.contentMaxWidth) -> some View {
        modifier(ContentWidthClamp(maxWidth: maxWidth))
    }
}
