import UIKit

enum ImagePrep {
    static func jpegForVision(_ image: UIImage, maxDimension: CGFloat = 1600, maxBytes: Int = 900_000) -> Data? {
        let upright = image.normalizedUp()
        let scaled = upright.scaledToFit(maxDimension: maxDimension)
        var quality: CGFloat = 0.78
        var data = scaled.jpegData(compressionQuality: quality)
        while let current = data, current.count > maxBytes, quality > 0.38 {
            quality -= 0.1
            data = scaled.jpegData(compressionQuality: quality)
        }
        return data
    }
}

private extension UIImage {
    func normalizedUp() -> UIImage {
        if imageOrientation == .up { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }

    func scaledToFit(maxDimension: CGFloat) -> UIImage {
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return self }
        let scale = maxDimension / longest
        let newSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
