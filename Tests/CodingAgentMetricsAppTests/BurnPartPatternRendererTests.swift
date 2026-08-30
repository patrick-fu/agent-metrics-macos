import AppKit
import Testing
@testable import CodingAgentMetricsApp

struct BurnPartPatternRendererTests {
    @Test func hatchTexturesPaintPartColourInkAndSolidStaysUniform() {
        for name in ["grid", "stripes", "triangle", "dots"] {
            let pixels = PatternPixels(of: BurnPartPatternRenderer.image(textureName: name, color: .systemBlue))
            #expect(pixels.inkCount * 2 <= pixels.count, "texture '\(name)' inks \(pixels.inkCount) of \(pixels.count) pixels, more than a hatch should")
            #expect(pixels.inkCount * 16 >= pixels.count, "texture '\(name)' inks only \(pixels.inkCount) of \(pixels.count) pixels")
            let offColour = pixels.inkIndices.filter { !pixels.isPartColour($0) }.count
            #expect(offColour == 0, "texture '\(name)' has \(offColour) ink pixels outside the part colour")
        }
        let solid = PatternPixels(of: BurnPartPatternRenderer.image(textureName: "solid", color: .systemBlue))
        #expect(solid.clearCount == 0, "solid texture leaves \(solid.clearCount) pixels unpainted")
        #expect(solid.inkCount == solid.count, "solid texture inks \(solid.inkCount) of \(solid.count) pixels")
        #expect(solid.inkIndices.allSatisfy(solid.isPartColour), "solid texture is not one uniform colour")
    }

    @Test func everyTextureStillPaintsOpaquePatternInk() {
        for name in ["grid", "stripes", "triangle", "dots", "solid"] {
            let pixels = PatternPixels(of: BurnPartPatternRenderer.image(textureName: name, color: .systemBlue))
            #expect(pixels.inkCount > 0, "texture '\(name)' paints no opaque pattern pixel at all")
        }
    }

    @Test func hatchTexturesLetTheDarkGroundShowThroughOutsideThePattern() {
        for name in ["grid", "stripes", "triangle", "dots"] {
            let pixels = PatternPixels(of: BurnPartPatternRenderer.image(textureName: name, color: .systemBlue))
            #expect(
                pixels.opaqueWhiteCount == 0,
                "texture '\(name)' paints \(pixels.opaqueWhiteCount) opaque white pixels over the ground"
            )
            #expect(
                pixels.clearCount * 4 >= pixels.count,
                "texture '\(name)' leaves only \(pixels.clearCount) of \(pixels.count) pixels fully transparent"
            )
            #expect(
                pixels.alphaSum * 2 <= pixels.count * 255,
                "texture '\(name)' covers more than half the tile, mean alpha \(pixels.alphaSum / max(pixels.count, 1))"
            )
        }
    }

    @Test func partTexturesStayDistinguishableFromEachOtherWithoutColour() {
        let textures = ["solid", "grid", "stripes", "triangle", "dots"]
        let rendered = textures.map { ($0, PatternPixels(of: BurnPartPatternRenderer.image(textureName: $0, color: .systemBlue))) }
        for left in rendered {
            for right in rendered where left.0 < right.0 {
                let differing = zip(left.1.inkMask, right.1.inkMask).filter { $0 != $1 }.count
                #expect(
                    differing * 8 >= left.1.count,
                    "textures '\(left.0)' and '\(right.0)' differ on only \(differing) of \(left.1.count) pixels"
                )
            }
        }
    }
}

/// Alpha-aware view of a rendered pattern, decoded in the test so the oracle stays independent of the renderer.
private struct PatternPixels {
    /// Premultiplied RGBA bytes, row-major.
    let bytes: [UInt8]

    init(of image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Issue.record("pattern image has no bitmap representation")
            self.bytes = []
            return
        }
        var decoded = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = CGContext(
            data: &decoded,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        self.bytes = decoded
    }

    var count: Int { bytes.count / 4 }

    private func pixel(_ index: Int) -> (red: Int, green: Int, blue: Int, alpha: Int) {
        let offset = index * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]), Int(bytes[offset + 3]))
    }

    /// Pixels with nothing painted at all, so the view behind the chart stays visible.
    var clearCount: Int { (0..<count).filter { pixel($0).alpha == 0 }.count }

    var opaqueWhiteCount: Int {
        (0..<count).filter {
            let value = pixel($0)
            return value.alpha == 255 && value.red >= 250 && value.green >= 250 && value.blue >= 250
        }.count
    }

    /// Pixels where the pattern ink is fully opaque.
    var inkIndices: [Int] { (0..<count).filter { pixel($0).alpha == 255 } }

    var inkCount: Int { inkIndices.count }

    /// Ink drawn with the blue part colour handed to the renderer rather than a neutral.
    func isPartColour(_ index: Int) -> Bool {
        let value = pixel(index)
        return value.blue > value.red && value.blue > value.green && value.red < 250
    }

    /// Total coverage of the tile, so an opaque ground cannot hide behind antialiasing.
    var alphaSum: Int { (0..<count).reduce(0) { $0 + pixel($1).alpha } }

    /// Which pixels the pattern inks, ignoring hue so textures stay comparable without colour.
    var inkMask: [Bool] { (0..<count).map { pixel($0).alpha == 255 } }
}
