import AppKit

// 生成应用 Logo（1024x1024 PNG）
// 设计：深色圆角面板上三张毛玻璃"应用卡片"（蓝/绿/橙圆点）+ 右下角一枚红色关闭徽章（白色 ✕）

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "assets/icon_1024.png"
let canvas: CGFloat = 1024

let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no graphics context") }

// macOS 风格圆角方形底板（824/1024，预留系统图标模板边距）
let shapeRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: shapeRect, cornerWidth: 184, cornerHeight: 184, transform: nil)
ctx.addPath(shape)
ctx.clip()

let colors = [
    CGColor(red: 0.31, green: 0.31, blue: 0.34, alpha: 1),
    CGColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1),
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// 顶部内侧高光
ctx.addPath(shape)
ctx.setLineWidth(3)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
ctx.strokePath()

// 2x2 网格：三张毛玻璃卡片 + 右下角红色关闭徽章
let card: CGFloat = 250
let gap: CGFloat = 40
let left = 512 - (card * 2 + gap) / 2
let top = 512 + (card * 2 + gap) / 2 - card
let bottom = 512 - (card * 2 + gap) / 2

func drawCard(_ x: CGFloat, _ y: CGFloat, dot: (CGFloat, CGFloat, CGFloat)) {
    let rect = CGRect(x: x, y: y, width: card, height: card)
    let path = CGPath(roundedRect: rect, cornerWidth: 56, cornerHeight: 56, transform: nil)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    ctx.addPath(path)
    ctx.fillPath()
    ctx.setLineWidth(4)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
    ctx.addPath(path)
    ctx.strokePath()
    ctx.setFillColor(CGColor(red: dot.0, green: dot.1, blue: dot.2, alpha: 0.95))
    ctx.fillEllipse(in: CGRect(x: x + card / 2 - 58, y: y + card / 2 - 58, width: 116, height: 116))
}

drawCard(left, top, dot: (0.04, 0.52, 1.00))
drawCard(left + card + gap, top, dot: (0.19, 0.82, 0.35))
drawCard(left, bottom, dot: (1.00, 0.62, 0.04))

let badge = CGRect(x: left + card + gap, y: bottom, width: card, height: card)
ctx.setFillColor(CGColor(red: 1.00, green: 0.27, blue: 0.23, alpha: 1))
ctx.fillEllipse(in: badge)
let c = CGPoint(x: badge.midX, y: badge.midY)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.setLineWidth(38)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: c.x - 60, y: c.y + 60))
ctx.addLine(to: CGPoint(x: c.x + 60, y: c.y - 60))
ctx.move(to: CGPoint(x: c.x + 60, y: c.y + 60))
ctx.addLine(to: CGPoint(x: c.x - 60, y: c.y - 60))
ctx.strokePath()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("PNG 编码失败")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("已生成 \(outPath)")
