import AppKit
let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let background = CGColor(red: 0.025, green: 0.045, blue: 0.04, alpha: 1)
ctx.setFillColor(background); ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
let palette: [(CGFloat, CGFloat, CGFloat)] = [(0.4,0.96,0.56),(0.56,0.83,1),(0.78,0.6,1),(1,0.75,0.37)]
for i in 0..<8 {
    let c = palette[i % 4]
    ctx.saveGState(); ctx.translateBy(x: 512, y: 512); ctx.rotate(by: CGFloat(i) * .pi / 8)
    ctx.setStrokeColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 0.68)); ctx.setLineWidth(3)
    let r = CGFloat(260 + i * 14)
    ctx.strokeEllipse(in: CGRect(x: -r, y: -r * 0.32, width: r * 2, height: r * 0.64))
    ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1)); ctx.fillEllipse(in: CGRect(x: r - 10, y: -10, width: 20, height: 20)); ctx.restoreGState()
}
ctx.setFillColor(background); ctx.fill(CGRect(x: 442, y: 367, width: 140, height: 290))
ctx.setStrokeColor(CGColor(red: 0.4, green: 0.96, blue: 0.56, alpha: 1)); ctx.setLineWidth(3)
ctx.addPath(CGPath(roundedRect: CGRect(x: 442, y: 367, width: 140, height: 290), cornerWidth: 25, cornerHeight: 25, transform: nil)); ctx.strokePath()
let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
