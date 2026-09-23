// 生成 App 图标（渲染一个 SF Symbol 到 PNG）
import AppKit

let args = CommandLine.arguments
guard args.count > 1 else { exit(1) }
let outputPath = args[1]
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// 圆角矩形底（渐变蓝紫）
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.06, dy: size * 0.06),
                        xRadius: size * 0.22, yRadius: size * 0.22)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.29, green: 0.47, blue: 0.98, alpha: 1),
    NSColor(calibratedRed: 0.55, green: 0.32, blue: 0.94, alpha: 1),
])
gradient?.draw(in: path, angle: -60)

// 中间的交换箭头
if let symbol = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: nil) {
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
    if let configured = symbol.withSymbolConfiguration(config) {
        let tinted = NSImage(size: configured.size)
        tinted.lockFocus()
        NSColor.white.set()
        let imageRect = NSRect(origin: .zero, size: configured.size)
        configured.draw(in: imageRect)
        imageRect.fill(using: .sourceAtop)
        tinted.unlockFocus()

        let targetRect = NSRect(
            x: (size - configured.size.width) / 2,
            y: (size - configured.size.height) / 2,
            width: configured.size.width,
            height: configured.size.height
        )
        tinted.draw(in: targetRect)
    }
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    exit(1)
}
try? png.write(to: URL(fileURLWithPath: outputPath))
