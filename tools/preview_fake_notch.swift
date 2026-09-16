// ─────────────────────────────────────────────────────────────
// 折叠态形状对照图
//
// 形状不在这个脚本里画 —— 它只搬运 app 自己算出来的两张遮罩，所以预览和真机
// 永远是同一个形状，不会各画各的跑偏：
//   /tmp/closeapps-mask@2x.png      无刘海屏那枚"假刘海"（176×30，高 = 菜单栏高）
//   /tmp/closeapps-capsule@2x.png   有刘海屏关掉「藏进刘海」时那枚胶囊（176×36）
// 两张的形状都是 border-radius: 0 0 16px 16px。
//
// 实现要点（踩过的坑）：
//   · 整张图只用一个 CGBitmapContext，遮罩以 CGImage 直接 blit。
//     绝对不要"离屏画布套离屏画布" —— NSImage.draw(in:) 对 rep.size ≠ 像素尺寸
//     的图会按像素尺寸当点来画，尺寸和位置全错（见 /tmp/t_nest.swift 最小复现）。
//   · 坐标系统一用 y 向下的"逻辑坐标"（左上角原点），文字靠
//     NSGraphicsContext(cgContext:flipped:) 保证正着排。
//   · blit 时自己翻一次 CTM，否则图会上下颠倒（不对称遮罩一眼就看出来）。
//
// 用法：
//   printf 'mask\nquit-now\n' | CLOSEAPPS_DEBUG=1 ./CloseApps.app/Contents/MacOS/CloseApps
//   swift tools/preview_fake_notch.swift
// ─────────────────────────────────────────────────────────────
import AppKit
import ImageIO

let argv = CommandLine.arguments
let notchPath   = argv.count > 1 ? argv[1] : "/tmp/closeapps-mask@2x.png"
let capsulePath = argv.count > 2 ? argv[2] : "/tmp/closeapps-capsule@2x.png"
let outPath     = argv.count > 3 ? argv[3] : "/tmp/closeapps-shape-preview.png"

// ── 调色 ──
enum Pal {
    static let bg      = NSColor(srgbRed: 0.055, green: 0.063, blue: 0.078, alpha: 1)
    static let boxBg   = NSColor(srgbRed: 0.075, green: 0.085, blue: 0.105, alpha: 1)
    static let ink     = NSColor(white: 1, alpha: 0.94)
    static let sub     = NSColor(white: 1, alpha: 0.62)
    static let dim     = NSColor(white: 1, alpha: 0.40)
    static let accent  = NSColor(srgbRed: 0.29, green: 0.86, blue: 0.71, alpha: 1)
    static let hair    = NSColor(white: 1, alpha: 0.11)
    static let barFill = NSColor(srgbRed: 0.115, green: 0.125, blue: 0.155, alpha: 0.98)
}

// ── 位图画布：单一 CGContext，逻辑坐标 y 向下 ──
final class Canvas {
    let cg: CGContext
    let scale: CGFloat
    let size: CGSize

    init(_ size: CGSize, scale: CGFloat) {
        self.size = size
        self.scale = scale
        let w = max(1, Int((size.width * scale).rounded()))
        let h = max(1, Int((size.height * scale).rounded()))
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            FileHandle.standardError.write(Data("建不出 \(w)x\(h) 位图上下文\n".utf8)); exit(1)
        }
        c.interpolationQuality = .high
        c.scaleBy(x: scale, y: scale)
        c.translateBy(x: 0, y: size.height)
        c.scaleBy(x: 1, y: -1)
        self.cg = c
    }

    /// 在这块画布上跑一段 AppKit 绘制（文字/渐变），flipped 保证正着排
    func ns(_ body: () -> Void) {
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        body()
        NSGraphicsContext.current = prev
    }

    var image: CGImage? { cg.makeImage() }

    func writePNG(_ path: String) -> Bool {
        guard let img = image, let data = NSBitmapImageRep(cgImage: img)
            .representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

// ── 文字 ──
func attrs(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor,
           mono: Bool) -> [NSAttributedString.Key: Any] {
    let f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                 : NSFont.systemFont(ofSize: size, weight: weight)
    let p = NSMutableParagraphStyle()
    p.lineBreakMode = .byClipping
    return [.font: f, .foregroundColor: color, .paragraphStyle: p]
}

func textWidth(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular,
               mono: Bool = false) -> CGFloat {
    (s as NSString).size(withAttributes: attrs(size, weight, Pal.ink, mono: mono)).width
}

func text(_ c: Canvas, _ s: String, x: CGFloat, y: CGFloat, size: CGFloat,
          _ weight: NSFont.Weight = .regular, _ color: NSColor = Pal.ink, mono: Bool = false) {
    c.ns {
        (s as NSString).draw(at: NSPoint(x: x, y: y),
                             withAttributes: attrs(size, weight, color, mono: mono))
    }
}

// ── CGImage 直贴（自己翻 CTM，否则上下颠倒）──
func blit(_ g: CGContext, _ img: CGImage, into rect: CGRect) {
    g.saveGState()
    g.translateBy(x: rect.minX, y: rect.maxY)
    g.scaleBy(x: 1, y: -1)
    g.draw(img, in: CGRect(origin: .zero, size: rect.size))
    g.restoreGState()
}

// ── 遮罩像素探针 ──
struct Probe {
    var topInsetPt = 0.0        // 顶行从左起第一个不透明像素的位置（pt）
    var bottomInsetPt = 0.0
    var topCornerPt = 0.0       // 上缘圆角"高度"：顶行起连续内缩的行数，直角时是 0
    var bottomCornerPt = 0.0    // 下缘圆角高度，直接对得上 border-radius 的 px 数
    var tl = 0, tr = 0, bl = 0, br = 0
}

func rawPixels(_ img: CGImage) -> (w: Int, h: Int, buf: [UInt8]) {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { raw in
        guard let c = CGContext(data: raw.baseAddress, width: w, height: h,
                                bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return (w, h, buf)
}

/// 从遮罩像素里读出形状。
///
/// 判据是"**x=0 这一列被盖住了多少**"，不是"第一个不透明像素在第几位"：
/// 圆角一路收到边缘的那几行，x=0 会被盖住 97%、90%、68%……（alpha 249 → 165 → …），
/// 用"不透明起点 > 0"去数会把这些缓收行整段漏掉，半径会被量小
/// （踩过：16pt 的圆角量成 12.0pt）。按覆盖率数就刚好等于半径。
func probe(_ img: CGImage, scale: CGFloat) -> Probe {
    let (w, h, buf) = rawPixels(img)
    func alpha(_ x: Int, _ y: Int) -> Int { Int(buf[(y * w + x) * 4 + 3]) }
    func coverage(_ x: Int, _ y: Int) -> Double { Double(alpha(x, y)) / 255.0 }

    /// 从顶（或底）往里数，"x=0 还没被完全盖住"的行数 —— 这个数就是圆角高度，也就是半径
    func cornerHeight(fromTop: Bool) -> Double {
        var n = 0.0
        for i in 0..<h {
            let y = fromTop ? i : h - 1 - i
            if coverage(0, y) >= 0.995 { break }
            n += 1
        }
        return n
    }

    /// 顶行 / 底行"从左边起第一个不透明像素"的位置（直角那一行是实心的，给 0）
    func firstOpaque(row y: Int) -> Int {
        for x in 0..<w where alpha(x, y) > 2 { return x }
        return w
    }

    var p = Probe()
    p.tl = alpha(0, 0); p.tr = alpha(w - 1, 0)
    p.bl = alpha(0, h - 1); p.br = alpha(w - 1, h - 1)
    p.topCornerPt = cornerHeight(fromTop: true) / Double(scale)
    p.bottomCornerPt = cornerHeight(fromTop: false) / Double(scale)
    p.topInsetPt = Double(firstOpaque(row: 0)) / Double(scale)
    p.bottomInsetPt = Double(firstOpaque(row: h - 1)) / Double(scale)
    return p
}

// ── 读遮罩 + 推逻辑尺寸 ──
func loadMask(_ path: String) -> (cg: CGImage, size: CGSize, scale: CGFloat)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var scale: CGFloat = 2                       // app 导出固定 @2x，兜底
    if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
       let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 1 {
        scale = CGFloat(dpi / 72.0)
    }
    let size = CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
    return (img, size, scale)
}

guard let notchMask = loadMask(notchPath), let capsuleMask = loadMask(capsulePath) else {
    FileHandle.standardError.write(Data("""
    找不到遮罩图：\(notchPath) / \(capsulePath)
    先让 app 把遮罩导出来：
      printf 'mask\\nquit-now\\n' | CLOSEAPPS_DEBUG=1 ./CloseApps.app/Contents/MacOS/CloseApps

    """.utf8))
    exit(1)
}

// ── 折叠条素材：深色玻璃 + 那点内容，再用真实遮罩抠形 ──
let barScale: CGFloat = 4                     // 放大镜要 ×2.7，素材精度给足
func makeBar(mask: CGImage, size: CGSize) -> CGImage {
    let c = Canvas(size, scale: barScale)
    let g = c.cg
    g.setFillColor(Pal.barFill.cgColor)
    g.fill(CGRect(origin: .zero, size: size))

    let label = "关闭应用"
    c.ns {
        let a = attrs(12.5, .semibold, Pal.ink, mono: false)
        let lw = (label as NSString).size(withAttributes: a).width
        let iconW: CGFloat = 15, gap: CGFloat = 7
        let x0 = (size.width - (iconW + gap + lw)) / 2
        let iy = (size.height - iconW) / 2
        NSColor(srgbRed: 0.44, green: 0.82, blue: 0.72, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: x0, y: iy, width: iconW, height: iconW),
                     xRadius: 4.2, yRadius: 4.2).fill()
        (label as NSString).draw(at: NSPoint(x: x0 + iconW + gap, y: (size.height - 15) / 2),
                                 withAttributes: a)
    }

    g.setBlendMode(.destinationIn)
    blit(g, mask, into: CGRect(origin: .zero, size: size))
    g.setBlendMode(.normal)
    return c.image!
}

let notchBar = makeBar(mask: notchMask.cg, size: notchMask.size)
let capsuleBar = makeBar(mask: capsuleMask.cg, size: capsuleMask.size)

// ── 一块"屏幕" ──
let panelW: CGFloat = 420, panelH: CGFloat = 300
let notchW: CGFloat = 185, notchH: CGFloat = 32
let menuH: CGFloat = 30

enum ScreenKind { case noNotch, withNotch }

/// 在 origin（面板左上角）处画一块屏幕顶部；局部坐标：y=0 就是屏幕最上沿
func drawScene(_ c: Canvas, origin: CGPoint, kind: ScreenKind,
               bar: CGImage, barSize: CGSize) {
    let g = c.cg
    let ox = origin.x, oy = origin.y
    let panel = CGRect(x: ox, y: oy, width: panelW, height: panelH)

    g.saveGState()
    g.addPath(CGPath(roundedRect: panel, cornerWidth: 12, cornerHeight: 12, transform: nil))
    g.clip()

    // 壁纸
    c.ns {
        NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.13, blue: 0.27, alpha: 1),
                            NSColor(srgbRed: 0.29, green: 0.16, blue: 0.34, alpha: 1),
                            NSColor(srgbRed: 0.46, green: 0.23, blue: 0.30, alpha: 1)])!
            .draw(in: NSRect(x: ox, y: oy, width: panelW, height: panelH), angle: -78)
    }

    // 菜单栏
    g.setFillColor(NSColor(white: 1, alpha: 0.14).cgColor)
    g.fill(CGRect(x: ox, y: oy, width: panelW, height: menuH))
    g.setFillColor(NSColor(white: 1, alpha: 0.22).cgColor)
    g.fill(CGRect(x: ox, y: oy + menuH, width: panelW, height: 0.5))

    c.ns {
        let a = attrs(10.5, .regular, NSColor(white: 1, alpha: 0.88), mono: false)
        var mx = ox + 14
        for item in ["Finder", "文件", "显示"] {
            (item as NSString).draw(at: NSPoint(x: mx, y: oy + 8), withAttributes: a)
            mx += (item as NSString).size(withAttributes: a).width + 13
        }
        let clock = "21:05"
        (clock as NSString).draw(at: NSPoint(x: ox + panelW - 14 - (clock as NSString).size(withAttributes: a).width,
                                             y: oy + 8), withAttributes: a)
    }

    // 刘海
    if kind == .withNotch {
        g.setFillColor(NSColor(srgbRed: 0.01, green: 0.01, blue: 0.016, alpha: 1).cgColor)
        g.addPath(CGPath(roundedRect: CGRect(x: ox + (panelW - notchW) / 2, y: oy,
                                             width: notchW, height: notchH),
                         cornerWidth: 9, cornerHeight: 9, transform: nil))
        g.fillPath()
    }

    // 折叠条本体（遮罩形状的真身）
    let bx = ox + (panelW - barSize.width) / 2
    let by = oy + (kind == .withNotch ? notchH : 0)
    blit(g, bar, into: CGRect(x: bx, y: by, width: barSize.width, height: barSize.height))

    g.restoreGState()

    // 面板细边
    g.setStrokeColor(NSColor(white: 1, alpha: 0.13).cgColor)
    g.setLineWidth(1)
    g.addPath(CGPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5),
                     cornerWidth: 12, cornerHeight: 12, transform: nil))
    g.strokePath()

    // 面板底部小注
    let note = kind == .withNotch
        ? "内置屏 · 1512×982 · 刘海 185×32"
        : "外接显示器 · 1920×1080 · 菜单栏 30pt"
    text(c, note, x: ox + 14, y: oy + panelH - 24, size: 10.5, .regular,
         NSColor(white: 1, alpha: 0.55))
}

/// 折叠条在这块面板里的局部矩形（放大镜要拿它描轮廓）
func barLocalRect(kind: ScreenKind, barSize: CGSize) -> CGRect {
    CGRect(x: (panelW - barSize.width) / 2,
           y: kind == .withNotch ? notchH : 0,
           width: barSize.width, height: barSize.height)
}

// ── 放大镜：把窗口那块重画一遍并放大，再描出遮罩真实轮廓 ──
func drawMagnifier(_ c: Canvas, box: CGRect, panelOrigin: CGPoint, win: CGRect,
                   kind: ScreenKind, bar: CGImage, barSize: CGSize) -> CGFloat {
    let g = c.cg
    let zoom = box.width / win.width
    let rounded = CGPath(roundedRect: box, cornerWidth: 10, cornerHeight: 10, transform: nil)

    g.saveGState()
    g.addPath(rounded); g.clip()
    g.setFillColor(Pal.boxBg.cgColor); g.fill(box)
    // 场景坐标 → 盒子坐标
    g.translateBy(x: box.minX, y: box.minY)
    g.scaleBy(x: zoom, y: zoom)
    g.translateBy(x: -(panelOrigin.x + win.minX), y: -(panelOrigin.y + win.minY))
    drawScene(c, origin: panelOrigin, kind: kind, bar: bar, barSize: barSize)
    g.restoreGState()

    // 遮罩真实轮廓（相对盒子）
    let bl = barLocalRect(kind: kind, barSize: barSize)
    let outline = CGRect(x: box.minX + (bl.minX - win.minX) * zoom,
                         y: box.minY + (bl.minY - win.minY) * zoom,
                         width: bl.width * zoom, height: bl.height * zoom)
    g.saveGState()
    g.addPath(rounded); g.clip()
    g.setStrokeColor(Pal.accent.cgColor)
    g.setLineWidth(1.2)
    g.stroke(outline)
    g.restoreGState()

    // 外圈
    g.setStrokeColor(NSColor(white: 1, alpha: 0.20).cgColor)
    g.setLineWidth(1)
    g.addPath(rounded); g.strokePath()
    return zoom
}

// ── 主画布 ──
let S: CGFloat = 2
let W: CGFloat = 940, H: CGFloat = 694
let canvas = Canvas(CGSize(width: W, height: H), scale: S)
let g = canvas.cg
g.setFillColor(Pal.bg.cgColor)
g.fill(CGRect(x: 0, y: 0, width: W, height: H))

// 标题
text(canvas, "折叠态的形状", x: 30, y: 24, size: 20, .semibold)
let css = "border-radius: 0 0 16px 16px"
let pillW = textWidth(css, 12.5, .medium, mono: true) + 28
let pill = CGRect(x: W - 30 - pillW, y: 22, width: pillW, height: 28)
g.setFillColor(NSColor(srgbRed: 0.29, green: 0.86, blue: 0.71, alpha: 0.13).cgColor)
g.addPath(CGPath(roundedRect: pill, cornerWidth: 8, cornerHeight: 8, transform: nil)); g.fillPath()
g.setStrokeColor(NSColor(srgbRed: 0.29, green: 0.86, blue: 0.71, alpha: 0.42).cgColor)
g.setLineWidth(1)
g.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil))
g.strokePath()
text(canvas, css, x: pill.minX + 14, y: pill.minY + 6.5, size: 12.5, .medium, Pal.accent, mono: true)

text(canvas, "两种折叠态共用同一个形状：上缘两个角是直角、下缘两个角 16pt 圆角。",
     x: 30, y: 58, size: 12.5, .regular, Pal.sub)
g.setFillColor(Pal.hair.cgColor)
g.fill(CGRect(x: 30, y: 92, width: W - 60, height: 1))

// 两块屏幕
let colX: [CGFloat] = [30, 490]
let panelsTop: CGFloat = 146
let pA = CGPoint(x: colX[0], y: panelsTop)
let pB = CGPoint(x: colX[1], y: panelsTop)

let spec: [(kind: ScreenKind, origin: CGPoint, bar: CGImage, size: CGSize,
            title: String, detail: String)] = [
    (.noNotch,   pA, notchBar,   notchMask.size,
     "无刘海屏（外接显示器）折叠态 = 假刘海",
     "\(Int(notchMask.size.width))×\(Int(notchMask.size.height))pt，高 = 菜单栏高，顶边贴着屏幕最上沿"),
    (.withNotch, pB, capsuleBar, capsuleMask.size,
     "有刘海屏 · 关掉「折叠时藏进刘海」 = 胶囊",
     "\(Int(capsuleMask.size.width))×\(Int(capsuleMask.size.height))pt，吊在刘海正下方"),
]

for s in spec {
    text(canvas, s.title, x: s.origin.x, y: 102, size: 13.5, .semibold)
    text(canvas, s.detail, x: s.origin.x, y: 121, size: 11.5, .regular, Pal.dim)
    drawScene(canvas, origin: s.origin, kind: s.kind, bar: s.bar, barSize: s.size)
}

// 放大镜区
text(canvas, "放大看那两个角 —— 青色细线就是遮罩真正的轮廓", x: 30, y: 470, size: 14, .semibold)

let probeA = probe(notchMask.cg, scale: notchMask.scale)
let probeB = probe(capsuleMask.cg, scale: capsuleMask.scale)

let boxSide: CGFloat = 140, boxesTop: CGFloat = 490
let winSide: CGFloat = 52

/// 读数三行：把"圆角高度"直接对到 border-radius 的 px 数上，不用人去换算内缩
func report(_ c: Canvas, _ p: Probe, x: CGFloat, y: CGFloat) {
    text(c, String(format: "上缘  圆角高度 %.1fpt   → 直角", p.topCornerPt),
         x: x, y: y, size: 11.5, .medium, Pal.ink, mono: true)
    text(c, String(format: "下缘  圆角高度 %.1fpt  → 16px 圆角", p.bottomCornerPt),
         x: x, y: y + 22, size: 11.5, .medium, Pal.accent, mono: true)
    text(c, "四角 alpha \(p.tl) / \(p.tr) / \(p.bl) / \(p.br)",
         x: x, y: y + 44, size: 11, .regular, Pal.dim, mono: true)
}

var zooms: [CGFloat] = []
for (i, s) in spec.enumerated() {
    let box = CGRect(x: colX[i], y: boxesTop, width: boxSide, height: boxSide)
    // 有刘海屏那枚胶囊要把刘海下沿也框进来，才看得清"上缘直角正好接上"
    let winY: CGFloat = s.kind == .withNotch ? 24 : 0
    let win = CGRect(x: (panelW - s.size.width) / 2 - 8, y: winY, width: winSide, height: winSide)
    let z = drawMagnifier(canvas, box: box, panelOrigin: s.origin, win: win,
                          kind: s.kind, bar: s.bar, barSize: s.size)
    zooms.append(z)
    text(canvas, String(format: "放大 ×%.1f", z),
         x: box.minX, y: box.maxY + 8, size: 11, .medium, NSColor(white: 1, alpha: 0.72))
    report(canvas, i == 0 ? probeA : probeB, x: box.maxX + 18, y: box.minY + 26)
}

text(canvas, "素材是 app 自测导出的真实遮罩，形状不在这里重画 —— 所以预览和真机永远是同一个形状。",
     x: 30, y: H - 30, size: 11, .regular, Pal.dim)

// ── 输出 ──
guard canvas.writePNG(outPath) else {
    FileHandle.standardError.write(Data("写 \(outPath) 失败\n".utf8)); exit(1)
}
print("已生成预览图: \(outPath)（\(Int(W * S))x\(Int(H * S))px，放大 ×\(String(format: "%.1f", zooms[0]))）")
print("假刘海 176×30：上缘圆角高度 \(String(format: "%.1f", probeA.topCornerPt))pt / "
      + "下缘圆角高度 \(String(format: "%.1f", probeA.bottomCornerPt))pt，"
      + "四角 alpha \(probeA.tl) \(probeA.tr) \(probeA.bl) \(probeA.br)")
print("胶囊   176×36：上缘圆角高度 \(String(format: "%.1f", probeB.topCornerPt))pt / "
      + "下缘圆角高度 \(String(format: "%.1f", probeB.bottomCornerPt))pt，"
      + "四角 alpha \(probeB.tl) \(probeB.tr) \(probeB.bl) \(probeB.br)")
