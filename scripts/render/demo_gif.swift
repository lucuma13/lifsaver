import AppKit

// Render the demo animation docs/images/demo.gif.
//
// Usage: swift demo_gif.swift   (requires ffmpeg: brew install ffmpeg)

// MARK: - Config

let projectRoot =
    URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let resourcesDir = projectRoot.appendingPathComponent("scripts/release/app-resources").path
let outputGif = projectRoot.appendingPathComponent("docs/images/demo.gif").path

// Scratch dir for the intermediate PNG frames + ffmpeg concat manifest.
let outputDir = NSTemporaryDirectory() + "lifsaver-demo-\(ProcessInfo.processInfo.processIdentifier)"
do {
    try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
} catch {
    fatalError("failed to create scratch dir \(outputDir): \(error)")
}
// The layout is authored in these logical points. renderScale draws each
// frame at 4x, and ffmpeg downsamples to a 1600x400 asset.
let canvasWidth: CGFloat = 800
let canvasHeight: CGFloat = 200
let renderScale: CGFloat = 4
let menuBarHeight: CGFloat = 26

func color(hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: alpha)
}

func loadImage(_ path: String) -> NSImage {
    guard let image = NSImage(contentsOfFile: path) else {
        fatalError("missing resource: \(path)")
    }
    return image
}

let templateIcon = loadImage("\(resourcesDir)/MenuBarIcon@3x.png")
let alertIcon = loadImage("\(resourcesDir)/MenuBarIconAlert@3x.png")
let appIcon = loadImage("\(resourcesDir)/AppIcon.icns")

func whiteTinted(_ image: NSImage, size: NSSize) -> NSImage {
    let result = NSImage(size: size)
    result.lockFocus()
    NSColor.white.set()
    NSRect(origin: .zero, size: size).fill()
    image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .destinationIn, fraction: 1)
    result.unlockFocus()
    return result
}

// MARK: - Frame model

enum IconState { case white, orange }

struct Frame {
    var icon: IconState = .white
    var bannerTop: CGFloat?  // top offset of the banner; nil = hidden
    var bannerAlpha: CGFloat = 1
    var menuOpen = false
    var highlight = false
    var cursor: NSPoint?
    var durationMs: Int
}

// MARK: - Drawing helpers (top-left logical coords)

func topRect(leftX: CGFloat, topY: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
    NSRect(x: leftX, y: canvasHeight - topY - height, width: width, height: height)
}

func drawText(_ text: String, font: NSFont, color textColor: NSColor, leftX: CGFloat, topY: CGFloat) {
    let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: textColor])
    let size = attributed.size()
    attributed.draw(at: NSPoint(x: leftX, y: canvasHeight - topY - size.height))
}

func textWidth(_ text: String, font: NSFont) -> CGFloat {
    NSAttributedString(string: text, attributes: [.font: font]).size().width
}

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func symbolImage(name: String, pointSize: CGFloat) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
    return base.withSymbolConfiguration(config)
}

func drawSymbolWhite(name: String, centerX: CGFloat, pointSize: CGFloat) {
    guard let image = symbolImage(name: name, pointSize: pointSize) else { return }
    let tinted = whiteTinted(image, size: image.size)
    let rect = NSRect(
        x: centerX - image.size.width / 2, y: canvasHeight - menuBarHeight / 2 - image.size.height / 2,
        width: image.size.width, height: image.size.height)
    tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.92)
}

// MARK: - Layout constants

let menuFont = NSFont.systemFont(ofSize: 13.5)
let mountFont = NSFont.systemFont(ofSize: 13.5, weight: .medium)
let barFont = NSFont.systemFont(ofSize: 11, weight: .medium)
let clockText = "9:41"
let clockLeftX = canvasWidth - 18 - textWidth(clockText, font: barFont)
let batteryCenterX = clockLeftX - 28
let wifiCenterX = batteryCenterX - 34
let iconCenterX = wifiCenterX - 31
let iconSize: CGFloat = 13

// Keep these menu items in sync with StatusMenuModel.entries.
let separatorTag = "—separator—"
let menuItems = [
    "Mount 2 stalled volumes", separatorTag, "Start at Login", "Send Diagnostic Report", "Check for Updates", "Quit",
]
let mountItem = menuItems[0]
let checkedItem = "Start at Login"  // shown enabled, with a checkmark
let rowHeight: CGFloat = 24
let separatorHeight: CGFloat = 9
let menuInsetX: CGFloat = 13
let menuInsetY: CGFloat = 5

func menuTextWidth() -> CGFloat {
    var widest: CGFloat = 0
    for item in menuItems where item != separatorTag {
        widest = max(widest, textWidth(item, font: menuFont))
    }
    return widest + menuInsetX * 2 + 22
}

let menuWidth = menuTextWidth()
let menuRightX = iconCenterX + iconSize / 2 + 8
let menuLeftX = menuRightX - menuWidth
let menuTopY = menuBarHeight + 5

func menuHeight() -> CGFloat {
    var total = menuInsetY * 2
    for item in menuItems { total += (item == separatorTag) ? separatorHeight : rowHeight }
    return total
}

// MARK: - Cursor

func drawCursor(at origin: NSPoint) {
    let points: [(CGFloat, CGFloat)] = [
        (0, 0), (0, 17), (4.6, 12.6), (7.8, 19.5), (10.4, 18.3), (7.2, 11.6), (12.4, 11.6),
    ]
    let unit: CGFloat = 0.86
    let path = NSBezierPath()
    for (index, point) in points.enumerated() {
        let vertex = NSPoint(x: origin.x + point.0 * unit, y: canvasHeight - (origin.y + point.1 * unit))
        if index == 0 { path.move(to: vertex) } else { path.line(to: vertex) }
    }
    path.close()
    path.lineJoinStyle = .round
    NSColor.black.withAlphaComponent(0.35).setStroke()
    path.lineWidth = 4
    path.stroke()
    NSColor.white.setFill()
    path.fill()
    NSColor.black.setStroke()
    path.lineWidth = 1
    path.stroke()
}

// MARK: - Frame sections

func drawBackground() {
    guard
        let wallpaper = NSGradient(
            colors: [color(hex: 0x3a2f60), color(hex: 0x233149)], atLocations: [0, 1], colorSpace: .sRGB)
    else { fatalError("gradient init failed") }
    wallpaper.draw(in: NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight), angle: -78)

    // translucent dark menu bar with a faint hairline underneath
    color(hex: 0x000000, alpha: 0.34).setFill()
    NSRect(x: 0, y: canvasHeight - menuBarHeight, width: canvasWidth, height: menuBarHeight).fill()
    color(hex: 0xffffff, alpha: 0.08).setFill()
    NSRect(x: 0, y: canvasHeight - menuBarHeight - 0.5, width: canvasWidth, height: 0.5).fill()

    drawText(
        clockText, font: barFont, color: color(hex: 0xffffff, alpha: 0.92),
        leftX: clockLeftX, topY: (menuBarHeight - barFont.capHeight) / 2 - 2)
    drawSymbolWhite(name: "battery.100", centerX: batteryCenterX, pointSize: 13)
    drawSymbolWhite(name: "wifi", centerX: wifiCenterX, pointSize: 11)
}

func drawStatusIcon(_ frame: Frame) {
    if frame.menuOpen {
        color(hex: 0xffffff, alpha: 0.16).setFill()
        roundedRect(
            NSRect(x: iconCenterX - 14, y: canvasHeight - menuBarHeight + 2, width: 28, height: menuBarHeight - 4),
            radius: 5
        ).fill()
    }
    let image =
        frame.icon == .white ? whiteTinted(templateIcon, size: NSSize(width: iconSize, height: iconSize)) : alertIcon
    let rect = NSRect(
        x: iconCenterX - iconSize / 2, y: canvasHeight - menuBarHeight / 2 - iconSize / 2,
        width: iconSize, height: iconSize)
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: frame.icon == .white ? 0.95 : 1)
}

func drawBanner(_ frame: Frame) {
    guard let bannerTop = frame.bannerTop else { return }
    let alpha = frame.bannerAlpha
    let bannerWidth: CGFloat = 340
    let bannerX = canvasWidth - 16 - bannerWidth
    let rect = topRect(leftX: bannerX, topY: bannerTop, width: bannerWidth, height: 80)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(hex: 0, alpha: 0.45 * alpha)
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.set()
    color(hex: 0x1c1c1e, alpha: 0.96 * alpha).setFill()
    roundedRect(rect, radius: 16).fill()
    NSGraphicsContext.restoreGraphicsState()

    color(hex: 0xffffff, alpha: 0.09 * alpha).setStroke()
    let border = roundedRect(rect, radius: 16)
    border.lineWidth = 0.75
    border.stroke()

    let appIconSize: CGFloat = 42
    appIcon.draw(
        in: NSRect(x: bannerX + 14, y: rect.maxY - 14 - appIconSize, width: appIconSize, height: appIconSize),
        from: .zero, operation: .sourceOver, fraction: alpha)
    let textX = bannerX + 14 + appIconSize + 12
    drawText(
        "lifsaver", font: NSFont.systemFont(ofSize: 13.5, weight: .semibold),
        color: color(hex: 0xffffff, alpha: 0.96 * alpha), leftX: textX, topY: bannerTop + 14)
    let nowFont = NSFont.systemFont(ofSize: 12)
    drawText(
        "now", font: nowFont, color: color(hex: 0xffffff, alpha: 0.5 * alpha),
        leftX: canvasWidth - 16 - 16 - textWidth("now", font: nowFont), topY: bannerTop + 15)
    // Keep in sync with StatusMenuModel.stalledNotificationBody.
    let body = NSAttributedString(
        string: "2 stalled volumes detected",
        attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color(hex: 0xffffff, alpha: 0.82 * alpha)])
    body.draw(in: topRect(leftX: textX, topY: bannerTop + 33, width: bannerWidth - (textX - bannerX) - 16, height: 40))
}

/// A small checkmark in the menu's left gutter, `centerY` in top-left coords.
func drawCheckmark(centerY: CGFloat) {
    let left = menuLeftX + 2.5
    // Short stroke down to the elbow, long stroke up to the tip.
    let points: [(CGFloat, CGFloat)] = [(0, 3.2), (2.6, 6), (7, 0)]
    let path = NSBezierPath()
    for (index, point) in points.enumerated() {
        let vertex = NSPoint(x: left + point.0, y: canvasHeight - (centerY - 3 + point.1))
        if index == 0 { path.move(to: vertex) } else { path.line(to: vertex) }
    }
    path.lineWidth = 1.6
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    color(hex: 0xffffff, alpha: 0.9).setStroke()
    path.stroke()
}

func drawMenu(_ frame: Frame) {
    guard frame.menuOpen else { return }
    let menuRect = topRect(leftX: menuLeftX, topY: menuTopY, width: menuWidth, height: menuHeight())

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(hex: 0, alpha: 0.5)
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    color(hex: 0x282828, alpha: 0.97).setFill()
    roundedRect(menuRect, radius: 9).fill()
    NSGraphicsContext.restoreGraphicsState()

    color(hex: 0xffffff, alpha: 0.10).setStroke()
    let border = roundedRect(menuRect, radius: 9)
    border.lineWidth = 0.75
    border.stroke()

    var rowTop = menuTopY + menuInsetY
    for item in menuItems {
        if item == separatorTag {
            color(hex: 0xffffff, alpha: 0.11).setFill()
            NSRect(
                x: menuLeftX + 10, y: canvasHeight - (rowTop + separatorHeight / 2) - 0.5,
                width: menuWidth - 20, height: 1
            ).fill()
            rowTop += separatorHeight
            continue
        }
        let isMount = item == mountItem
        if isMount && frame.highlight {
            color(hex: 0x0a63ff).setFill()
            roundedRect(
                topRect(leftX: menuLeftX + 5, topY: rowTop + 1, width: menuWidth - 10, height: rowHeight - 2),
                radius: 5
            ).fill()
        }
        let textColor = (isMount && frame.highlight) ? NSColor.white : color(hex: 0xffffff, alpha: 0.9)
        let font = isMount ? mountFont : menuFont
        // "Start at Login" is enabled in the demo — show the checkmark a real
        // macOS menu draws in the left gutter of a checked item. Hand-drawn at
        // a fixed size so it stays within the inset, clear of the text.
        if item == checkedItem {
            drawCheckmark(centerY: rowTop + rowHeight / 2)
        }
        drawText(
            item, font: font, color: textColor,
            leftX: menuLeftX + menuInsetX, topY: rowTop + (rowHeight - font.capHeight - 8) / 2 + 1)
        rowTop += rowHeight
    }
}

// MARK: - Render one frame

func renderFrame(_ frame: Frame, to path: String) {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(canvasWidth * renderScale),
            pixelsHigh: Int(canvasHeight * renderScale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("bitmap allocation failed") }
    rep.size = NSSize(width: canvasWidth, height: canvasHeight)
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("context init failed") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawBackground()
    drawStatusIcon(frame)
    drawBanner(frame)
    drawMenu(frame)
    if let cursor = frame.cursor { drawCursor(at: cursor) }
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("png encoding failed") }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        fatalError("failed to write \(path): \(error)")
    }
}

// MARK: - Timeline

let mountRowCenterY = menuTopY + menuInsetY + rowHeight / 2  // top offset of the first row's centre
let cursorOnItem = NSPoint(x: menuLeftX + menuWidth - 60, y: mountRowCenterY - 4)
let cursorAtIcon = NSPoint(x: iconCenterX - 2, y: menuBarHeight + 2)

let frames: [Frame] = [
    Frame(icon: .white, durationMs: 1000),  // normal
    Frame(icon: .orange, bannerTop: -46, bannerAlpha: 0.35, durationMs: 55),  // banner sliding in
    Frame(icon: .orange, bannerTop: 6, bannerAlpha: 0.8, durationMs: 55),  // banner sliding in
    Frame(icon: .orange, bannerTop: 34, durationMs: 1750),  // alert held
    Frame(icon: .orange, menuOpen: true, cursor: cursorAtIcon, durationMs: 700),  // menu opened
    Frame(icon: .orange, menuOpen: true, highlight: true, cursor: cursorOnItem, durationMs: 950),  // item highlighted
    Frame(icon: .orange, menuOpen: true, cursor: cursorOnItem, durationMs: 110),  // click flash off
    Frame(icon: .orange, menuOpen: true, highlight: true, cursor: cursorOnItem, durationMs: 150),  // click flash on
    Frame(icon: .orange, cursor: cursorOnItem, durationMs: 230),  // menu closed, mounting
    Frame(icon: .white, durationMs: 1150),  // back to normal
]

for (index, frame) in frames.enumerated() {
    renderFrame(frame, to: String(format: "\(outputDir)/f%03d.png", index))
}

// ffmpeg concat manifest with per-frame durations (the last file is repeated,
// as the concat demuxer ignores the final entry's duration).
var concat = ""
for (index, frame) in frames.enumerated() {
    concat += "file 'f\(String(format: "%03d", index)).png'\nduration \(Double(frame.durationMs) / 1000)\n"
}
concat += "file 'f\(String(format: "%03d", frames.count - 1)).png'\n"
do {
    try concat.write(toFile: "\(outputDir)/concat.txt", atomically: true, encoding: .utf8)
} catch {
    fatalError("failed to write concat.txt: \(error)")
}

// MARK: - Stitch frames into the GIF (ffmpeg)

func ffmpeg(_ args: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ffmpeg"] + args
    process.standardOutput = FileHandle.nullDevice  // ffmpeg is chatty; stay quiet
    process.standardError = FileHandle.nullDevice
    // Detach stdin: with an inherited TTY, ffmpeg enters interactive mode and
    // blocks on a keypress read, hanging the render.
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        fatalError("could not launch ffmpeg: \(error)")
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        fatalError("ffmpeg failed (\(process.terminationStatus)); install it: brew install ffmpeg")
    }
}

let filter = "scale=1600:400:flags=lanczos"  // 2:1 supersample down to the 2x asset size
let concatFile = "\(outputDir)/concat.txt"
let palette = "\(outputDir)/palette.png"

// Pass 1: optimised palette from the frames
ffmpeg([
    "-y", "-f", "concat", "-safe", "0", "-i", concatFile,
    "-vf", "\(filter),palettegen=stats_mode=diff", palette,
])
// Pass 2: apply the palette and honour the per-frame durations
ffmpeg([
    "-y", "-f", "concat", "-safe", "0", "-i", concatFile, "-i", palette,
    "-lavfi", "\(filter)[x];[x][1:v]paletteuse=dither=sierra2_4a",
    "-fps_mode", "vfr", "-loop", "0", outputGif,
])

try? FileManager.default.removeItem(atPath: outputDir)
print("rendered \(outputGif)")
