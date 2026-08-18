import PDFKit
import UIKit

enum SessionPDFExporter {
    static func export(entries: [SessionInterviewEntry], summaryZh: String, language: UILanguage = .zh) -> URL? {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { ctx in
            var y: CGFloat = 48
            func newPage() {
                ctx.beginPage()
                y = 48
            }
            func draw(_ text: String, font: UIFont, color: UIColor = .black, indent: CGFloat = 36) {
                let width = pageRect.width - indent - 36
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: color
                ]
                let bounding = (text as NSString).boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: attrs,
                    context: nil
                )
                if y + bounding.height > pageRect.height - 48 {
                    newPage()
                }
                (text as NSString).draw(in: CGRect(x: indent, y: y, width: width, height: bounding.height), withAttributes: attrs)
                y += bounding.height + 8
            }

            newPage()
            draw(L10n.t(.pdfTitle, language: language), font: .boldSystemFont(ofSize: 20))
            draw(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short), font: .systemFont(ofSize: 11), color: .darkGray)
            draw(L10n.t(.pdfSummary, language: language), font: .boldSystemFont(ofSize: 14))
            draw(summaryZh, font: .systemFont(ofSize: 12))

            for (i, e) in entries.enumerated() {
                draw("Q\(i + 1)", font: .boldSystemFont(ofSize: 14))
                if let raw = e.interviewerQuestionRaw, !raw.isEmpty {
                    draw(String(format: L10n.t(.pdfInterviewer, language: language), raw), font: .systemFont(ofSize: 11), color: .darkGray)
                }
                draw(String(format: L10n.t(.pdfQuestion, language: language), e.questionZh), font: .systemFont(ofSize: 12))
                draw(String(format: L10n.t(.pdfConcise, language: language), e.conciseAnswerEn), font: .systemFont(ofSize: 12))
                if let expanded = e.expandedAnswerEn, !expanded.isEmpty {
                    draw(String(format: L10n.t(.pdfExpanded, language: language), expanded), font: .systemFont(ofSize: 12))
                }
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("guoleme-session.pdf")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
