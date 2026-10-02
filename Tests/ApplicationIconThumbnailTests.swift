import Foundation
import CoreGraphics
import ImageIO

/// Real image generation/decoding exercises the production thumbnail helper.
/// No device, network, UIKit, or simulator behavior is mocked.
@main
enum ApplicationIconThumbnailTests {
    struct Failure: Error, CustomStringConvertible { let description: String }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(description: message) }
    }

    static func image(width: Int, height: Int, transparent: Bool = false) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw Failure(description: "Could not create test image")
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: transparent ? 0.25 : 1)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        guard let image = context.makeImage() else { throw Failure(description: "Could not finish test image") }
        return image
    }

    static func encode(_ image: CGImage, type: String, orientation: Int? = nil) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else {
            throw Failure(description: "Could not create image encoder")
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if let orientation { properties[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try expect(CGImageDestinationFinalize(destination), "Could not encode test image")
        return data as Data
    }

    static func thumbnail(_ data: Data) throws -> (Data, CGImage) {
        guard let result = ApplicationIconThumbnail.make(data),
              let source = CGImageSourceCreateWithData(result as CFData, nil),
              let type = CGImageSourceGetType(source),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw Failure(description: "Valid input did not produce a decodable thumbnail")
        }
        try expect(type as String == "public.png", "Thumbnail is not PNG")
        try expect(result.count <= 256 * 1024, "Encoded thumbnail exceeds cache limit")
        try expect(image.width <= 144 && image.height <= 144, "Decoded thumbnail exceeds pixel limit")
        return (result, image)
    }

    static func alpha(_ image: CGImage, x: Int, y: Int) throws -> UInt8 {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw Failure(description: "Could not read thumbnail pixels")
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes[(y * image.width + x) * 4 + 3]
    }

    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("Landscape PNG downsampling preserves aspect ratio", {
                let source = try encode(image(width: 1200, height: 600), type: "public.png")
                let (_, result) = try thumbnail(source)
                try expect(result.width == 144 && result.height == 72, "Landscape aspect ratio changed")
            }),
            ("Portrait JPEG becomes a bounded PNG", {
                let source = try encode(image(width: 400, height: 1200), type: "public.jpeg")
                let (_, result) = try thumbnail(source)
                try expect(result.width == 48 && result.height == 144, "Portrait aspect ratio changed")
            }),
            ("Small icons are not enlarged", {
                let source = try encode(image(width: 60, height: 40), type: "public.png")
                let (_, result) = try thumbnail(source)
                try expect(result.width == 60 && result.height == 40, "Small icon was unnecessarily upscaled")
            }),
            ("PNG transparency survives thumbnail encoding", {
                let source = try encode(image(width: 600, height: 300, transparent: true), type: "public.png")
                let (_, result) = try thumbnail(source)
                let opaque = try alpha(result, x: result.width / 4, y: result.height / 2)
                let transparent = try alpha(result, x: result.width * 3 / 4, y: result.height / 2)
                try expect(opaque >= 250, "Opaque half lost alpha")
                try expect((55...75).contains(Int(transparent)), "Quarter-alpha half lost transparency: \(transparent)")
            }),
            ("EXIF rotation is applied before caching", {
                let source = try encode(image(width: 800, height: 400), type: "public.jpeg", orientation: 6)
                let (_, result) = try thumbnail(source)
                try expect(result.width == 72 && result.height == 144, "EXIF orientation was ignored")
            }),
            ("Empty and non-image bytes are rejected", {
                for data in [Data(), Data("not an image".utf8), Data([0, 1, 2, 3, 4, 5])] {
                    try expect(ApplicationIconThumbnail.make(data) == nil, "Malformed bytes became an icon")
                }
            }),
            ("Incomplete PNG headers are rejected", {
                let source = try encode(image(width: 300, height: 300), type: "public.png")
                try expect(ApplicationIconThumbnail.make(Data(source.prefix(16))) == nil, "Truncated header became an icon")
            }),
            ("Image input over 8 MB is rejected before decoding", {
                var source = try encode(image(width: 300, height: 300), type: "public.png")
                source.append(Data(repeating: 0, count: 8 * 1024 * 1024 + 1 - source.count))
                try expect(ApplicationIconThumbnail.make(source) == nil, "Oversized image was accepted")
            }),
            ("Thumbnail generation leaves source bytes unchanged", {
                let source = try encode(image(width: 192, height: 192), type: "public.png")
                let original = source
                let (result, _) = try thumbnail(source)
                try expect(source == original, "Source bytes were modified")
                try expect(result != source, "Large source was cached without downsampling")
            })
        ]
        var failures = 0
        for (name, run) in tests {
            do { try run(); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        print("\(tests.count - failures)/\(tests.count) application icon tests passed")
        if failures > 0 { exit(1) }
    }
}
