import SwiftUI
import AppKit
import CoreText

// MARK: - Inter font registration + access

/// Registers the bundled Inter faces with Core Text and exposes a weight-matched
/// accessor with a graceful fall-through to the system font. Works both under
/// `swift run` (SwiftPM resource bundle) and in the hand-assembled `.app`
/// (build_app.sh copies the faces into Contents/Resources/Fonts).
enum InterFonts {
    private static let faces = ["Inter-Regular", "Inter-Medium", "Inter-SemiBold", "Inter-Bold"]

    /// Call once, as early as possible, before any text renders.
    static func registerAll() {
        for f in faces { register(f) }
    }

    private static func register(_ name: String) {
        guard let url = locate(name) else { return }
        var err: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &err)
        // An "already registered" error (code 105) is expected on re-entry; ignore.
    }

    private static func locate(_ name: String) -> URL? {
        if let u = Bundle.module.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") { return u }
        if let u = Bundle.module.url(forResource: name, withExtension: "ttf") { return u }
        if let u = Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") { return u }
        if let u = Bundle.main.url(forResource: name, withExtension: "ttf") { return u }
        return nil
    }
}

enum InterWeight {
    case regular, medium, semibold, bold
    var psName: String {
        switch self {
        case .regular:  return "Inter-Regular"
        case .medium:   return "Inter-Medium"
        case .semibold: return "Inter-SemiBold"
        case .bold:     return "Inter-Bold"
        }
    }
    var systemWeight: Font.Weight {
        switch self {
        case .regular:  return .regular
        case .medium:   return .medium
        case .semibold: return .semibold
        case .bold:     return .bold
        }
    }
}

enum AppFont {
    /// True once Inter resolves. Cached.
    static let interAvailable: Bool = { NSFont(name: "Inter-Regular", size: 12) != nil }()

    /// Inter at a weight/size, with Dynamic Type scaling, falling back to weight-matched SF.
    static func inter(_ weight: InterWeight, _ size: CGFloat,
                      relativeTo style: Font.TextStyle = .body) -> Font {
        interAvailable ? .custom(weight.psName, size: size, relativeTo: style)
                       : .system(size: size, weight: weight.systemWeight)
    }

    /// Editorial serif for big display headings — RenderPlus uses Fraunces; the native
    /// New York serif (`design: .serif`) is the closest match with zero bundling.
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}
