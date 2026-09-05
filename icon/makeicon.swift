import AppKit

// Gera icon_1024.png: ventoinha branca sobre um fundo gradiente "gelado".
// Uso: swift makeicon.swift  (roda dentro da pasta icon/)

let size: CGFloat = 1024

// Aplica um tom solido num simbolo template.
func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    image.draw(at: .zero, from: NSRect(origin: .zero, size: image.size),
               operation: .sourceOver, fraction: 1)
    color.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Fundo: squircle com gradiente indigo -> ciano (sensacao de frescor).
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let squircle = NSBezierPath(roundedRect: rect, xRadius: size * 0.2237, yRadius: size * 0.2237)
squircle.addClip()
let top = NSColor(calibratedRed: 0.31, green: 0.27, blue: 0.90, alpha: 1)    // #4F46E5
let bottom = NSColor(calibratedRed: 0.02, green: 0.71, blue: 0.83, alpha: 1)  // #06B6D4
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [top.cgColor, bottom.cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

// Simbolo da ventoinha, branco, centralizado.
let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
if let base = NSImage(systemSymbolName: "fanblades.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(cfg) {
    let white = tinted(base, .white)
    let s = white.size
    white.draw(at: NSPoint(x: (size - s.width) / 2, y: (size - s.height) / 2),
               from: NSRect(origin: .zero, size: s), operation: .sourceOver, fraction: 1)
}

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("falha ao gerar PNG\n".utf8)); exit(1)
}
try! png.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("icon_1024.png gerado")
