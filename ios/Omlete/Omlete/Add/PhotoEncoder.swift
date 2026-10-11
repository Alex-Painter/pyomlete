import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum PhotoEncoder {
    /// A photo from the library as an upright JPEG no longer than `longestSide`
    /// pixels. The server reads JPEG, and a full-size photo is megabytes that a
    /// recipe page does not need. nil when the data is not an image.
    static func jpeg(from data: Data, longestSide: Int = 2000) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? encoded as Data : nil
    }
}
