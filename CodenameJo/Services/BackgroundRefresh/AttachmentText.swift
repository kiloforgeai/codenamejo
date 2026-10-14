import Foundation
import PDFKit
import UIKit

/// One attachment turned into text for a tool result: read on the phone where the bytes are
/// already text, otherwise digested by OpenAI on the user's own key. Never throws.
enum AttachmentText {
    enum Kind: Equatable { case pdf, image, text, rtf, office, unsupported }

    static let maxBytes = 6_000_000
    static let maxChars = 8_000
    /// Below this a PDF "extraction" is page furniture, so the file is really a scan.
    static let minExtractedChars = 120

    static let instruction =
        "Read this attachment and write a dense factual digest for another assistant "
        + "to answer questions from. Lead with one sentence saying what the document is. "
        + "Then the specifics that matter: names, amounts, dates, deadlines, decisions "
        + "asked for, and anything that looks like it needs a reply. Keep every figure "
        + "exact. No preamble, no markdown, no bullet characters. If the document is "
        + "mostly boilerplate, say so in one line rather than reproducing it."

    typealias Reader = ([[String: Any]]) async throws -> String

    static func read(_ bytes: Data, filename: String, mimeType: String,
                     model: @escaping Reader = { try await LiveOpenAI.read($0) }) async -> String {
        let kind = classify(filename: filename, mimeType: mimeType)
        if bytes.count > maxBytes {
            return "\(filename) is \(describeSize(bytes.count)), too big to read aloud on the phone. "
                + "Tell the user its name and size, say you can't read this one, and leave it there."
        }
        switch kind {
        case .unsupported:
            return "\(filename) is a \(formatName(filename, mimeType)), which cannot be read here — "
                + "PDFs, images, Word, Excel, PowerPoint and plain text can. Say that plainly, name "
                + "the file, and stop there. Do not guess what is in it."
        case .text:
            let text = String(decoding: bytes, as: UTF8.self)
                .replacingOccurrences(of: "\\s+\\n", with: "\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return "\(filename) is empty." }
            return "\(filename) (\(describeSize(bytes.count))), read in full:\n\n\(clamp(text))"
        case .rtf:
            let text = (try? NSAttributedString(data: bytes,
                options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))?.string ?? ""
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "\(filename) could not be opened — it may be damaged. Say that plainly and don't guess what is in it."
            }
            return await localRead(text, filename: filename, size: bytes.count, model: model)
        case .pdf:
            if let text = PDFDocument(data: bytes)?.string,
               text.trimmingCharacters(in: .whitespacesAndNewlines).count >= minExtractedChars {
                return await localRead(text, filename: filename, size: bytes.count, model: model)
            }
        case .image, .office:
            break
        }
        let encoded = bytes.base64EncodedString()
        let part: [String: Any] = kind == .image
            ? ["type": "input_image", "detail": "auto", "image_url": "data:\(mimeType);base64,\(encoded)"]
            : ["type": "input_file", "filename": filename,
               "file_data": "data:\(fileMime(kind, filename: filename, mimeType: mimeType));base64,\(encoded)"]
        do {
            let digest = try await model([["type": "input_text", "text": instruction], part])
            guard !digest.isEmpty else {
                return "\(filename) came back with nothing readable in it. Say that rather than guessing."
            }
            return "\(filename) (\(describeSize(bytes.count))):\n\n\(clamp(digest))"
        } catch {
            RealtimeLog.log("attachment: read \(filename) failed — \(error.localizedDescription)")
            return (error as? URLError)?.code == .timedOut
                ? "\(filename) took too long to read. Tell the user it timed out and offer to try again."
                : "\(filename) could not be read (\(error.localizedDescription.prefix(120))). Say so plainly."
        }
    }

    /// Short extractions go back whole; long ones are digested, or clamped with a warning if that fails.
    static func localRead(_ text: String, filename: String, size: Int, model: Reader) async -> String {
        let tidied = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if tidied.count <= maxChars {
            return "\(filename) (\(describeSize(size))), read in full:\n\n\(tidied)"
        }
        guard let digest = try? await model([["type": "input_text", "text": instruction + "\n\n" + tidied]]),
              !digest.isEmpty else {
            return "\(filename) (\(describeSize(size))), too long to summarise — this is the start of it "
                + "only, so say that before answering from it:\n\n\(clamp(tidied))"
        }
        return "\(filename) (\(describeSize(size))):\n\n\(clamp(digest))"
    }

    /// Extension first: mail clients send `application/octet-stream` far too often.
    static func classify(filename: String, mimeType: String) -> Kind {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "pdf" || mimeType == "application/pdf" { return .pdf }
        if ext == "rtf" { return .rtf }
        if ["docx", "xlsx", "pptx", "odt", "ods", "odp"].contains(ext) { return .office }
        if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) { return .image }
        if mimeType.hasPrefix("image/") && mimeType != "image/heic" { return .image }
        if ["txt", "md", "csv", "tsv", "json", "log", "xml", "yml", "yaml"].contains(ext) { return .text }
        if mimeType.hasPrefix("text/") || mimeType == "application/json" { return .text }
        return .unsupported
    }

    private static func fileMime(_ kind: Kind, filename: String, mimeType: String) -> String {
        if kind == .pdf { return "application/pdf" }
        let byExt = [
            "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            "odt": "application/vnd.oasis.opendocument.text",
            "ods": "application/vnd.oasis.opendocument.spreadsheet",
            "odp": "application/vnd.oasis.opendocument.presentation",
        ]
        return byExt[(filename as NSString).pathExtension.lowercased()] ?? mimeType
    }

    static func formatName(_ filename: String, _ mimeType: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        let named = [
            "doc": "Word document", "xls": "Excel spreadsheet", "ppt": "PowerPoint deck",
            "key": "Keynote deck", "pages": "Pages document", "numbers": "Numbers spreadsheet",
            "zip": "zip archive", "heic": "HEIC photo", "mp4": "video", "mov": "video",
            "mp3": "audio file", "m4a": "audio file",
        ]
        return named[ext] ?? (ext.isEmpty ? (mimeType.isEmpty ? "file of unknown type" : mimeType) : ".\(ext) file")
    }

    static func describeSize(_ bytes: Int) -> String {
        if bytes < 1_000 { return "\(bytes) bytes" }
        if bytes < 1_000_000 { return "\(bytes / 1_000) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    static func clamp(_ text: String) -> String {
        text.count > maxChars ? String(text.prefix(maxChars)) + "… [truncated]" : text
    }
}
