// make_icons.swift
//
// Generates AppIcon.icns and ArchiveIcon.icns for 7-Zip for macOS.
// The .icns files are stored in repository, so this script is required
// only if you want to change the icons:
//
//   cd CPP/7zip/UI/MacOS/Resources
//   swift make_icons.swift

import AppKit

func squirclePath(_ rect: NSRect) -> NSBezierPath {
  let r = rect.width * 0.2237
  return NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
}

func roundedFont(_ size: CGFloat) -> NSFont {
  let base = NSFont.systemFont(ofSize: size, weight: .black)
  if let d = base.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) {
    return f
  }
  return base
}

func drawText(_ text: String, in rect: NSRect, size: CGFloat, color: NSColor, dy: CGFloat = 0) {
  let attrs: [NSAttributedString.Key: Any] = [
    .font: roundedFont(size),
    .foregroundColor: color,
    .kern: -size * 0.04,
  ]
  let s = NSAttributedString(string: text, attributes: attrs)
  let b = s.size()
  s.draw(at: NSPoint(x: rect.midX - b.width / 2, y: rect.midY - b.height / 2 + dy))
}

// zipper: two rows of teeth
func drawZipper(in rect: NSRect, color: NSColor) {
  let n = 9
  let w = rect.width / CGFloat(n)
  for i in 0..<n {
    let x = rect.minX + CGFloat(i) * w
    let tooth = NSRect(x: x + w * 0.18, y: (i % 2 == 0) ? rect.midY : rect.minY, width: w * 0.64, height: rect.height / 2)
    color.setFill()
    NSBezierPath(roundedRect: tooth, xRadius: w * 0.15, yRadius: w * 0.15).fill()
  }
}

func drawAppIcon(_ s: CGFloat) {
  let inset = s * 100 / 1024
  let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)

  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
  shadow.shadowBlurRadius = s * 0.025
  shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
  shadow.set()
  let path = squirclePath(rect)
  NSGradient(colors: [
    NSColor(calibratedRed: 0.24, green: 0.26, blue: 0.30, alpha: 1),
    NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1),
  ])!.draw(in: path, angle: -90)
  NSGraphicsContext.restoreGraphicsState()

  // top highlight
  NSGraphicsContext.saveGraphicsState()
  squirclePath(rect).addClip()
  let hl = NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
  NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0.0)])!
    .draw(in: hl, angle: -90)
  NSGraphicsContext.restoreGraphicsState()

  // inner border
  NSColor.white.withAlphaComponent(0.08).setStroke()
  let border = squirclePath(rect.insetBy(dx: s * 0.004, dy: s * 0.004))
  border.lineWidth = s * 0.006
  border.stroke()

  drawText("7z", in: rect, size: rect.height * 0.50, color: .white, dy: rect.height * 0.06)

  let zr = NSRect(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.17,
                  width: rect.width * 0.56, height: rect.height * 0.085)
  drawZipper(in: zr, color: NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.10, alpha: 1))
}

func drawArchiveIcon(_ s: CGFloat) {
  // document page with folded corner
  let w = s * 0.70, h = s * 0.86
  let x = (s - w) / 2, y = (s - h) / 2
  let fold = w * 0.26
  let page = NSBezierPath()
  page.move(to: NSPoint(x: x, y: y))
  page.line(to: NSPoint(x: x + w, y: y))
  page.line(to: NSPoint(x: x + w, y: y + h - fold))
  page.line(to: NSPoint(x: x + w - fold, y: y + h))
  page.line(to: NSPoint(x: x, y: y + h))
  page.close()

  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
  shadow.shadowBlurRadius = s * 0.02
  shadow.shadowOffset = NSSize(width: 0, height: -s * 0.008)
  shadow.set()
  NSGradient(colors: [NSColor(white: 1.0, alpha: 1), NSColor(white: 0.93, alpha: 1)])!.draw(in: page, angle: -90)
  NSGraphicsContext.restoreGraphicsState()

  NSColor(white: 0.75, alpha: 1).setStroke()
  page.lineWidth = max(1, s * 0.004)
  page.stroke()

  let corner = NSBezierPath()
  corner.move(to: NSPoint(x: x + w - fold, y: y + h))
  corner.line(to: NSPoint(x: x + w - fold, y: y + h - fold))
  corner.line(to: NSPoint(x: x + w, y: y + h - fold))
  corner.close()
  NSColor(white: 0.82, alpha: 1).setFill()
  corner.fill()
  corner.stroke()

  // badge
  let bs = w * 0.62
  let badge = NSRect(x: s / 2 - bs / 2, y: y + h * 0.18, width: bs, height: bs)
  let bp = squirclePath(badge)
  NSGradient(colors: [
    NSColor(calibratedRed: 0.24, green: 0.26, blue: 0.30, alpha: 1),
    NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1),
  ])!.draw(in: bp, angle: -90)
  drawText("7z", in: badge, size: bs * 0.50, color: .white, dy: bs * 0.06)
  let zr = NSRect(x: badge.minX + bs * 0.22, y: badge.minY + bs * 0.15, width: bs * 0.56, height: bs * 0.09)
  drawZipper(in: zr, color: NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.10, alpha: 1))
}

func render(_ size: Int, _ draw: (CGFloat) -> Void) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  draw(CGFloat(size))
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

func makeIcns(_ name: String, _ draw: @escaping (CGFloat) -> Void) throws {
  let fm = FileManager.default
  let dir = URL(fileURLWithPath: fm.temporaryDirectory.path).appendingPathComponent("\(name).iconset")
  try? fm.removeItem(at: dir)
  try fm.createDirectory(at: dir, withIntermediateDirectories: true)
  for base in [16, 32, 128, 256, 512] {
    try render(base, draw).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2, draw).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
  }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
  p.arguments = ["-c", "icns", dir.path, "-o", "\(name).icns"]
  try p.run()
  p.waitUntilExit()
  try? fm.removeItem(at: dir)
}

try makeIcns("AppIcon", drawAppIcon)
try makeIcns("ArchiveIcon", drawArchiveIcon)
