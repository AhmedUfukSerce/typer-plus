//
//  Glyphs.swift
//  Typer+ — custom-drawn brand, mode, and empty-state marks (pure SwiftUI Canvas).
//
//  House style: stroke ≈ 7.5% of the smaller side, round caps + joins, monochrome
//  ink + a single teal accent, ~70% fill with air around it, geometry derived
//  from the rect so everything scales crisp.
//

import SwiftUI

private extension CGRect {
    var glyphStroke: CGFloat { min(width, height) * 0.075 }
}

// MARK: - Brand mark: a keyboard slab with a teal spacebar (matches the app icon)

struct TyperMark: View {
    var accent: Color = Theme.accent          // teal #1C6B5E — the spacebar
    var ink: Color = Theme.textPrimary
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: size.width * 0.08, dy: size.height * 0.08)
            let s = r.glyphStroke
            let bodyStyle = StrokeStyle(lineWidth: s, lineCap: .round, lineJoin: .round)

            // Keyboard body: a wide rounded slab (landscape silhouette inside the square).
            let bodyH = r.height * 0.74
            let body = CGRect(x: r.minX, y: r.midY - bodyH / 2, width: r.width, height: bodyH)
            let bodyPath = Path(roundedRect: body, cornerRadius: bodyH * 0.26, style: .continuous)
            ctx.fill(bodyPath, with: .color(ink.opacity(0.05)))
            ctx.stroke(bodyPath, with: .color(ink), style: bodyStyle)

            let pad = bodyH * 0.20
            let inner = body.insetBy(dx: pad, dy: pad)
            let gapY = inner.height * 0.16
            let rowH = (inner.height - gapY * 2) / 3
            let keyR = rowH * 0.34
            let keyFill = GraphicsContext.Shading.color(ink.opacity(0.16))
            func keyTile(_ rect: CGRect) {
                ctx.fill(Path(roundedRect: rect, cornerRadius: keyR, style: .continuous), with: keyFill)
            }

            // Row 0: 3 keys. Row 1: 2 keys (staggered). Row 2: teal spacebar.
            tiles(in: inner, y: inner.minY, height: rowH, count: 3, gap: inner.width * 0.12, draw: keyTile)
            let mid = inner.insetBy(dx: inner.width * 0.14, dy: 0)
            tiles(in: mid, y: inner.minY + rowH + gapY, height: rowH, count: 2, gap: mid.width * 0.16, draw: keyTile)
            let row2Y = inner.minY + (rowH + gapY) * 2
            let space = CGRect(x: inner.minX, y: row2Y, width: inner.width, height: rowH)
            ctx.fill(Path(roundedRect: space, cornerRadius: keyR, style: .continuous), with: .color(accent))
        }
    }

    private func tiles(in box: CGRect, y: CGFloat, height: CGFloat, count: Int,
                       gap: CGFloat, draw: (CGRect) -> Void) {
        guard count > 0 else { return }
        let keyW = (box.width - gap * CGFloat(count - 1)) / CGFloat(count)
        for i in 0..<count {
            draw(CGRect(x: box.minX + CGFloat(i) * (keyW + gap), y: y, width: keyW, height: height))
        }
    }
}

// MARK: - Empty-state illustrations

struct EmptyHistoryArt: View {
    var ink: Color = Theme.textSecondary
    var accent: Color = Theme.accent
    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            let s = max(1.4, min(size.width, size.height) * 0.018)
            let faint = StrokeStyle(lineWidth: s, lineCap: .round)
            let style = StrokeStyle(lineWidth: s * 1.15, lineCap: .round, lineJoin: .round)
            for i in 0..<3 {
                let y = r.minY + r.height * (0.30 + Double(i) * 0.10)
                let inset = r.width * (0.30 + Double(i) * 0.06)
                var line = Path()
                line.move(to: CGPoint(x: r.minX + inset, y: y)); line.addLine(to: CGPoint(x: r.maxX - inset, y: y))
                ctx.stroke(line, with: .color(ink.opacity(0.18)), style: faint)
            }
            let c = CGPoint(x: r.midX, y: r.midY + r.height * 0.06)
            let radius = min(r.width, r.height) * 0.26
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)),
                       with: .color(ink.opacity(0.55)), style: style)
            var hands = Path()
            hands.move(to: CGPoint(x: c.x, y: c.y - radius * 0.62)); hands.addLine(to: c)
            hands.addLine(to: CGPoint(x: c.x + radius * 0.50, y: c.y + radius * 0.30))
            ctx.stroke(hands, with: .color(accent), style: style)
        }
    }
}


// MARK: - Typing dots (in-button liveness)

struct TypingDots: View {
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle().frame(width: 4, height: 4).foregroundStyle(.white)
                    .phaseAnimator([0.35, 1.0, 0.35]) { dot, opacity in dot.opacity(opacity) }
                        animation: { _ in .easeInOut(duration: 0.5).delay(Double(i) * 0.12) }
            }
        }
    }
}
