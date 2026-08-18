import AppKit
import CoreGraphics

enum BurnPartPatternRenderer {
    static func image(textureName: String, color: NSColor, size: CGSize = CGSize(width: 16, height: 16)) -> NSImage {
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return NSImage(size: size)
        }
        draw(textureName: textureName, color: color.usingColorSpace(.deviceRGB)?.cgColor ?? color.cgColor, in: context, size: CGSize(width: width, height: height))
        guard let cgImage = context.makeImage() else {
            return NSImage(size: size)
        }
        return NSImage(cgImage: cgImage, size: size)
    }

    static func distinctColorCount(in image: NSImage) -> Int {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return 0 }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var colors = Set<UInt32>()
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let packed = (UInt32(pixels[index]) << 16) | (UInt32(pixels[index + 1]) << 8) | UInt32(pixels[index + 2])
            colors.insert(packed)
        }
        return colors.count
    }

    static func draw(textureName: String, color: CGColor, in context: CGContext, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(bounds)
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(1)

        switch textureName {
        case "grid":
            var x: CGFloat = 2
            while x < size.width {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: size.height))
                x += 4
            }
            var y: CGFloat = 2
            while y < size.height {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: size.width, y: y))
                y += 4
            }
            context.strokePath()
        case "stripes":
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x + size.height, y: size.height))
                x += 3
            }
            context.strokePath()
        case "triangle":
            var y: CGFloat = 1
            while y < size.height {
                var x: CGFloat = 1
                while x < size.width {
                    context.move(to: CGPoint(x: x, y: y))
                    context.addLine(to: CGPoint(x: x + 2, y: y + 3))
                    context.addLine(to: CGPoint(x: x + 4, y: y))
                    context.closePath()
                    x += 6
                }
                y += 5
            }
            context.fillPath()
        case "dots":
            var y: CGFloat = 2
            while y < size.height {
                var x: CGFloat = 2
                while x < size.width {
                    context.fillEllipse(in: CGRect(x: x, y: y, width: 2, height: 2))
                    x += 4
                }
                y += 4
            }
        default:
            context.setFillColor(color)
            context.fill(bounds)
        }
    }
}
