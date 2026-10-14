import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let folder = root.appendingPathComponent("GravelFit/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
let sizes = [16,32,64,128,256,512,1024]
for size in sizes {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let clip = CGPath(roundedRect: CGRect(x: 48,y: 48,width: 928,height: 928),cornerWidth: 205,cornerHeight: 205,transform: nil)
    context.addPath(clip); context.clip()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: [CGColor(red: 0.055,green: 0.1,blue: 0.15,alpha: 1),CGColor(red: 0.05,green: 0.3,blue: 0.32,alpha: 1)] as CFArray, locations: [0,1])!
    context.drawLinearGradient(gradient,start: CGPoint(x: 100,y: 100),end: CGPoint(x: 900,y: 950),options: [])
    context.setLineCap(.round); context.setLineJoin(.round)
    context.setStrokeColor(CGColor(red: 0.2,green: 0.91,blue: 0.79,alpha: 1))
    context.setLineWidth(28)
    for x in [290.0,735.0] { context.strokeEllipse(in: CGRect(x: x - 140,y: 220,width: 280,height: 280)) }
    context.setStrokeColor(CGColor(red: 0.93,green: 0.99,blue: 0.98,alpha: 1))
    context.setLineWidth(25)
    let lines: [[CGPoint]] = [
        [CGPoint(x: 290,y: 360),CGPoint(x: 420,y: 610),CGPoint(x: 540,y: 360),CGPoint(x: 290,y: 360)],
        [CGPoint(x: 420,y: 610),CGPoint(x: 665,y: 610),CGPoint(x: 540,y: 360)],
        [CGPoint(x: 735,y: 360),CGPoint(x: 650,y: 670),CGPoint(x: 735,y: 670),CGPoint(x: 755,y: 625)],
        [CGPoint(x: 420,y: 610),CGPoint(x: 397,y: 674)],
        [CGPoint(x: 360,y: 680),CGPoint(x: 446,y: 680)],
        [CGPoint(x: 540,y: 360),CGPoint(x: 585,y: 305),CGPoint(x: 615,y: 305)]
    ]
    for line in lines { context.beginPath(); context.addLines(between: line); context.strokePath() }
    for point in [CGPoint(x: 420,y: 610),CGPoint(x: 540,y: 360),CGPoint(x: 665,y: 610)] {
        context.setFillColor(CGColor(red: 0.2,green: 0.91,blue: 0.79,alpha: 1)); context.fillEllipse(in: CGRect(x: point.x - 20,y: point.y - 20,width: 40,height: 40))
    }
    let url = folder.appendingPathComponent("icon-\(size).png")
    let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,context.makeImage()!,nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write icon") }
}
var images: [[String:String]] = []
for base in [16,32,128,256,512] {
    for scale in [1,2] { images.append(["idiom":"mac","size":"\(base)x\(base)","scale":"\(scale)x","filename":"icon-\(base * scale).png"]) }
}
let contents: [String:Any] = ["images":images,"info":["author":"xcode","version":1]]
try JSONSerialization.data(withJSONObject: contents,options: [.prettyPrinted,.sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
try Data("{\"info\":{\"author\":\"xcode\",\"version\":1}}".utf8).write(to: folder.deletingLastPathComponent().appendingPathComponent("Contents.json"))
