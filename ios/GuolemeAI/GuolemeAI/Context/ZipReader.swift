import Compression
import Foundation

enum ZipReader {
    static func data(named pathSuffix: String, in zip: Data) throws -> Data? {
        var offset = 0
        let bytes = [UInt8](zip)
        while offset + 30 < bytes.count {
            guard bytes[offset] == 0x50, bytes[offset + 1] == 0x4B,
                  bytes[offset + 2] == 0x03, bytes[offset + 3] == 0x04 else { break }
            let method = UInt16(bytes[offset + 8]) | UInt16(bytes[offset + 9]) << 8
            let compSize = int32(bytes, offset + 18)
            let uncompSize = int32(bytes, offset + 22)
            let nameLen = Int(UInt16(bytes[offset + 26]) | UInt16(bytes[offset + 27]) << 8)
            let extraLen = Int(UInt16(bytes[offset + 28]) | UInt16(bytes[offset + 29]) << 8)
            let nameStart = offset + 30
            let nameEnd = nameStart + nameLen
            guard nameEnd <= bytes.count else { break }
            let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8) ?? ""
            let dataStart = nameEnd + extraLen
            let dataEnd = dataStart + Int(compSize)
            guard dataEnd <= bytes.count else { break }
            if name == pathSuffix || name.hasSuffix(pathSuffix) {
                let payload = Data(bytes[dataStart..<dataEnd])
                if method == 0 { return payload }
                if method == 8 {
                    var zlib = Data([0x78, 0x9C])
                    zlib.append(payload)
                    return inflate(zlib, uncompressedSize: Int(uncompSize))
                }
                return nil
            }
            offset = dataEnd
        }
        return nil
    }

    private static func int32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private static func inflate(_ data: Data, uncompressedSize: Int) -> Data? {
        let dstSize = max(uncompressedSize, data.count * 4)
        var dst = Data(count: dstSize)
        let result = dst.withUnsafeMutableBytes { dstPtr in
            data.withUnsafeBytes { srcPtr in
                compression_decode_buffer(
                    dstPtr.bindMemory(to: UInt8.self).baseAddress!,
                    dstSize,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard result > 0 else { return nil }
        dst.removeSubrange(result..<dst.count)
        return dst
    }
}
