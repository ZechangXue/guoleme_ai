import Foundation
import PDFKit
import UniformTypeIdentifiers

enum DocumentImporter {
    static func text(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url)
        switch ext {
        case "txt", "md":
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? ""
        case "pdf":
            return pdfText(data: data)
        case "docx":
            return try docxText(data: data)
        default:
            if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
                return utf8
            }
            throw NSError(domain: "DocumentImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "不支持的文件类型：.\(ext)"])
        }
    }

    static func pdfText(data: Data) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        var parts: [String] = []
        for i in 0..<document.pageCount {
            if let page = document.page(at: i), let text = page.string, !text.isEmpty {
                parts.append(text)
            }
        }
        return parts.joined(separator: "\n")
    }

    static func docxText(data: Data) throws -> String {
        guard let xml = try ZipReader.data(named: "word/document.xml", in: data),
              let raw = String(data: xml, encoding: .utf8) else {
            throw NSError(domain: "DocumentImporter", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法解析 DOCX"])
        }
        var text = raw.replacingOccurrences(of: "</w:p>", with: "\n")
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return text
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let allowedTypes: [UTType] = [.pdf, .plainText, .text, UTType(filenameExtension: "docx")].compactMap { $0 }
}
