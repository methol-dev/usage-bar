import AppKit

private let labelWidth: CGFloat = 14
private let barWidth: CGFloat = 24
private let barHeight: CGFloat = 5
private let rowGap: CGFloat = 3
private let labelGap: CGFloat = 2
private let cornerRadius: CGFloat = 2
private let logoSize: CGFloat = 12
private let logoGap: CGFloat = 2
private let barsWidth: CGFloat = labelWidth + labelGap + barWidth + 2
private let iconWidth: CGFloat = logoSize + logoGap + barsWidth
private let iconHeight: CGFloat = 18
private let fontSize: CGFloat = 8

private struct CachedLabel {
    let string: NSAttributedString
    let size: NSSize
}

// 窗口短标签集合很小（"5h"/"7d"/"S"/"W" 等），按需生成 + 缓存；菜单栏重绘在 main，dict 不需锁。
private var labelCache: [String: CachedLabel] = [:]
private func cachedLabel(_ s: String) -> CachedLabel {
    if let hit = labelCache[s] { return hit }
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let str = NSAttributedString(string: s, attributes: attrs)
    let entry = CachedLabel(string: str, size: str.size())
    labelCache[s] = entry
    return entry
}

private func drawRow(label: String, barX: CGFloat, barY: CGFloat, labelX: CGFloat, drawBarFill: (CGFloat, CGFloat) -> Void) {
    let cached = cachedLabel(label)
    let labelY = barY + (barHeight - cached.size.height) / 2
    cached.string.draw(at: NSPoint(x: labelX + labelWidth - cached.size.width, y: labelY))
    drawBarFill(barX, barY)
}

func renderIcon(providerID: ProviderID, primaryLabel: String, secondaryLabel: String, pct5h: Double, pct7d: Double) -> NSImage {
    let image = NSImage(size: NSSize(width: iconWidth, height: iconHeight), flipped: true) { _ in
        let offset = logoSize + logoGap
        let barX = offset + labelWidth + labelGap
        let topY = (iconHeight - barHeight * 2 - rowGap) / 2
        let bottomY = topY + barHeight + rowGap

        drawProviderGlyph(for: providerID, x: 0, y: (iconHeight - logoSize) / 2, size: logoSize)

        drawRow(label: primaryLabel, barX: barX, barY: topY, labelX: offset) { x, y in
            drawBar(x: x, y: y, width: barWidth, height: barHeight, cornerRadius: cornerRadius, pct: pct5h)
        }
        drawRow(label: secondaryLabel, barX: barX, barY: bottomY, labelX: offset) { x, y in
            drawBar(x: x, y: y, width: barWidth, height: barHeight, cornerRadius: cornerRadius, pct: pct7d)
        }
        return true
    }
    image.isTemplate = true
    return image
}

func renderUnauthenticatedIcon(providerID: ProviderID, primaryLabel: String, secondaryLabel: String) -> NSImage {
    let image = NSImage(size: NSSize(width: iconWidth, height: iconHeight), flipped: true) { _ in
        let offset = logoSize + logoGap
        let barX = offset + labelWidth + labelGap
        let topY = (iconHeight - barHeight * 2 - rowGap) / 2
        let bottomY = topY + barHeight + rowGap

        drawProviderGlyph(for: providerID, x: 0, y: (iconHeight - logoSize) / 2, size: logoSize)

        drawRow(label: primaryLabel, barX: barX, barY: topY, labelX: offset) { x, y in
            drawDashedBar(x: x, y: y, width: barWidth, height: barHeight, cornerRadius: cornerRadius)
        }
        drawRow(label: secondaryLabel, barX: barX, barY: bottomY, labelX: offset) { x, y in
            drawDashedBar(x: x, y: y, width: barWidth, height: barHeight, cornerRadius: cornerRadius)
        }
        return true
    }
    image.isTemplate = true
    return image
}

// MARK: - Composite (multi-provider)

/// 将多张 provider icon（isTemplate NSImage）横向拼合为一张图，中间绘制竖向分隔线。
/// 解决 SwiftUI MenuBarExtra label 中 ForEach 多张 template NSImage 只渲第一张的问题。
func compositeIcons(_ icons: [NSImage]) -> NSImage {
    guard icons.count > 1 else { return icons.first ?? NSImage() }
    let divW: CGFloat = 1
    let gap: CGFloat = 6
    let spacing = gap + divW + gap
    let totalWidth = icons.reduce(0) { $0 + $1.size.width } + CGFloat(icons.count - 1) * spacing
    let height = icons.map(\.size.height).max() ?? iconHeight

    let composed = NSImage(size: NSSize(width: totalWidth, height: height), flipped: true) { _ in
        var x: CGFloat = 0
        for (i, icon) in icons.enumerated() {
            if i > 0 {
                let divRect = NSRect(x: x, y: height * 0.15, width: divW, height: height * 0.7)
                NSColor.black.withAlphaComponent(0.35).setFill()
                NSBezierPath(rect: divRect).fill()
                x += divW + gap
            }
            icon.draw(in: NSRect(x: x, y: 0, width: icon.size.width, height: height))
            x += icon.size.width
            if i < icons.count - 1 { x += gap }
        }
        return true
    }
    composed.isTemplate = true
    return composed
}

// MARK: - Bar drawing

private func drawBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, cornerRadius: CGFloat, pct: Double) {
    let bgRect = NSRect(x: x, y: y, width: width, height: height)
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor.black.withAlphaComponent(0.25).setFill()
    bgPath.fill()

    let clampedPct = max(0, min(1, pct))
    if clampedPct > 0 {
        let fillWidth = width * clampedPct
        let fillRect = NSRect(x: x, y: y, width: fillWidth, height: height)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.black.setFill()
        fillPath.fill()
    }
}

private func drawDashedBar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, cornerRadius: CGFloat) {
    let rect = NSRect(x: x, y: y, width: width, height: height)
    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor.black.withAlphaComponent(0.25).setStroke()
    path.lineWidth = 1
    let dashPattern: [CGFloat] = [2, 2]
    path.setLineDash(dashPattern, count: 2, phase: 0)
    path.stroke()
}

// MARK: - Provider glyph

/// Claude / Codex 用预渲染的 512px template PNG（源 SVG 来自 lobehub/lobe-icons，MIT —— 见 THIRD_PARTY_LICENSES.txt）；
/// 其它 provider 不带专属图片资源 —— 用 SF Symbol 渲染成 template image。
private func loadResourcePNG(_ name: String) -> NSImage? {
    if let bundle = usageBarResourceBundle(),
       let png = bundle.url(forResource: name, withExtension: "png") {
        return NSImage(contentsOf: png)
    }
    return nil
}
private let claudeLogoImage: NSImage? = loadResourcePNG("claude-logo")  // 源：icons.lobehub.com/components/claude
private let codexLogoImage: NSImage? = loadResourcePNG("codex-logo")    // 源：icons.lobehub.com/components/codex（macos/scripts/codex-logo.svg）

/// Codex glyph 的兜底：`codex-logo.png` 资源缺失时自绘的 `</>` 标记（描边、圆角接头）—— **非任何品牌 logo**，只是「代码生成」的通用符号。
/// 在 `NSImage(size:flipped: true)` 的绘图上下文里：小 y = 视觉上方，所以 `top`(小 y) 在上、`bot`(大 y) 在下、`/` 从右上到左下。
private func drawCodeBracketsGlyph(x: CGFloat, y: CGFloat, size: CGFloat) {
    let lw = max(size * 0.16, 1.4)
    let path = NSBezierPath()
    path.lineWidth = lw
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    let cx = x + size / 2
    let top = y + size * 0.20, bot = y + size * 0.80, mid = y + size / 2
    let lOuter = x + size * 0.10, lInner = x + size * 0.36
    let rOuter = x + size * 0.90, rInner = x + size * 0.64
    // `<`
    path.move(to: NSPoint(x: lInner, y: top)); path.line(to: NSPoint(x: lOuter, y: mid)); path.line(to: NSPoint(x: lInner, y: bot))
    // `>`
    path.move(to: NSPoint(x: rInner, y: top)); path.line(to: NSPoint(x: rOuter, y: mid)); path.line(to: NSPoint(x: rInner, y: bot))
    // `/`（中间斜杠：右上 → 左下）
    path.move(to: NSPoint(x: cx + size * 0.10, y: top)); path.line(to: NSPoint(x: cx - size * 0.10, y: bot))
    NSColor.black.setStroke()
    path.stroke()
}

private func sfSymbolName(for id: ProviderID) -> String {
    switch id {
    case .claude:  return "sparkles"            // 不会用到（claude 走 PNG），留个兜底
    case .codex:   return "terminal"
    case .cursor:  return "cursorarrow.rays"
    case .copilot: return "chevron.left.forwardslash.chevron.right"
    case .gemini:  return "sparkle"
    }
}

private func drawProviderGlyph(for id: ProviderID, x: CGFloat, y: CGFloat, size: CGFloat) {
    if id == .claude, let logo = claudeLogoImage {
        logo.draw(in: NSRect(x: x, y: y, width: size, height: size))
        return
    }
    if id == .codex {
        if let logo = codexLogoImage {
            logo.draw(in: NSRect(x: x, y: y, width: size, height: size))
        } else {
            drawCodeBracketsGlyph(x: x, y: y, size: size)
        }
        return
    }
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
    if let sym = NSImage(systemSymbolName: sfSymbolName(for: id), accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        sym.isTemplate = true
        // SF Symbol 实际尺寸可能略大于 size；居中绘进 size×size 框。
        let s = sym.size
        let scale = min(size / max(s.width, 1), size / max(s.height, 1))
        let w = s.width * scale, h = s.height * scale
        sym.draw(in: NSRect(x: x + (size - w) / 2, y: y + (size - h) / 2, width: w, height: h))
    }
}
