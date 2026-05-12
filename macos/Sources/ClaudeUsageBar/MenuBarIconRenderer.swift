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

/// Claude 用预渲染的 512px template PNG；其它 provider 不带专属图片资源 —— 用 SF Symbol 渲染成 template image。
private let claudeLogoImage: NSImage? = {
    if let bundle = claudeUsageBarResourceBundle(),
       let png = bundle.url(forResource: "claude-logo", withExtension: "png") {
        return NSImage(contentsOf: png)
    }
    return nil
}()

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
