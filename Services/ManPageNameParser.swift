import Compression
import Foundation

/// In-process man-page `NAME` extraction (spec §2.5) — file read + zlib
/// inflate only, per DL-5. Handles classic man (`.SH NAME`) and mdoc
/// (`.Sh NAME` with `.Nm`/`.Nd`) macros; output still goes through the
/// harvested-text sanitizer at the call site.
enum ManPageNameParser {
    static let maximumInflatedBytes = 1024 * 1024   // DL-15

    /// Raw or gzip-compressed man-page bytes → the one-line NAME summary
    /// (the part after the dash), or nil when no NAME section exists.
    static func nameSummary(from data: Data) -> String? {
        var text: String
        if data.starts(with: [0x1F, 0x8B]) {
            guard let inflated = gunzip(data, maxOutputBytes: maximumInflatedBytes) else {
                return nil
            }
            text = String(decoding: inflated, as: UTF8.self)
        } else {
            text = String(decoding: data, as: UTF8.self)
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        var sawNameSection = false
        var collected = [String]()
        var mdocName: String?
        var mdocDescription: String?

        while index < lines.count {
            let line = String(lines[index])
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if !sawNameSection {
                if isNameHeading(trimmed) {
                    sawNameSection = true
                }
                continue
            }
            if isSectionHeading(trimmed) {
                break
            }
            if trimmed.isEmpty || trimmed.hasPrefix(".\\\"") || trimmed.hasPrefix("'\\\"") {
                continue
            }
            if trimmed.hasPrefix(".Nm") {
                let value = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { mdocName = value }
                continue
            }
            if trimmed.hasPrefix(".Nd") {
                mdocDescription = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if trimmed.hasPrefix(".") || trimmed.hasPrefix("'") {
                continue   // other roff requests carry no NAME prose
            }
            collected.append(trimmed)
        }

        guard sawNameSection else { return nil }
        if let mdocDescription, !mdocDescription.isEmpty {
            return unescapedRoff(mdocDescription)
        }
        if collected.isEmpty {
            if let mdocName { return unescapedRoff(mdocName) }
            return nil
        }

        let joined = collected.joined(separator: " ")
        let summary = summaryAfterDash(in: joined)
        let unescaped = unescapedRoff(summary)
        return unescaped.isEmpty ? nil : unescaped
    }

    private static func isNameHeading(_ line: String) -> Bool {
        for prefix in [".SH", ".Sh"] where line.hasPrefix(prefix) {
            let rest = String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if rest.uppercased() == "NAME" {
                return true
            }
        }
        return false
    }

    private static func isSectionHeading(_ line: String) -> Bool {
        line.hasPrefix(".SH") || line.hasPrefix(".Sh") || line.hasPrefix(".SS")
    }

    /// "rg \- recursively search…" → "recursively search…". Falls back to the
    /// whole line when no dash separates name from description.
    private static func summaryAfterDash(in line: String) -> String {
        for separator in ["\\-", "\\(em", " - ", " – "] {
            if let range = line.range(of: separator) {
                return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return line
    }

    /// Minimal roff unescaping per spec: `\-` → `-`, strip `\f…` font
    /// switches, drop `\&` non-printing anchors.
    static func unescapedRoff(_ value: String) -> String {
        var text = value
        text = text.replacingOccurrences(of: #"\\f\([A-Z0-9]{2}"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\\f[A-Z0-9]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\-", with: "-")
        text = text.replacingOccurrences(of: "\\&", with: "")
        text = text.replacingOccurrences(of: "\\ ", with: " ")
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// gzip container → inflated bytes, capped. The gzip header is parsed by
    /// hand; the DEFLATE stream inflates through the Compression framework.
    static func gunzip(_ data: Data, maxOutputBytes: Int) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else {
            return nil
        }
        guard data[data.startIndex + 2] == 0x08 else { return nil }   // DEFLATE only
        let flags = data[data.startIndex + 3]
        var offset = data.startIndex + 10

        if flags & 0x04 != 0 {   // FEXTRA
            guard data.count >= offset + 2 else { return nil }
            let extraLength = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 {   // FNAME
            guard let nul = data[offset...].firstIndex(of: 0x00) else { return nil }
            offset = nul + 1
        }
        if flags & 0x10 != 0 {   // FCOMMENT
            guard let nul = data[offset...].firstIndex(of: 0x00) else { return nil }
            offset = nul + 1
        }
        if flags & 0x02 != 0 {   // FHCRC
            offset += 2
        }
        guard offset < data.endIndex else { return nil }

        let deflated = data[offset...]
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: maxOutputBytes)
        defer { destination.deallocate() }

        let inflatedCount = deflated.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(
                destination,
                maxOutputBytes,
                base,
                raw.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
        guard inflatedCount > 0 else { return nil }
        return Data(bytes: destination, count: inflatedCount)
    }
}
