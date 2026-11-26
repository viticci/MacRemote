import Foundation

/// A SKILL.md frontmatter block, read exactly (SPEC D84).
///
/// MacRemote serves a skill's frontmatter as JSON next to the file, so the two
/// must agree. It reads a small, documented part of YAML and refuses
/// everything else with a sentence the owner can read, rather than guess:
///
/// - The block opens with a `---` line at the very start of the file and ends
///   at the next `---` line that starts in the first column. Lines end in
///   `\n` or `\r\n`.
/// - Top-level `key: value` entries, one per key. A key is plain or quoted,
///   and may have spaces before its colon.
/// - A value is a plain, single-quoted, or double-quoted scalar on one line,
///   with an optional `# comment`; a `|` or `>` block scalar with an optional
///   `-` or `+` chomping indicator; or a map of one-line text values, one
///   level deep (`metadata:`). Their lines are indented with spaces; YAML
///   readers refuse a tab there, so this reader does too.
/// - Spaces and tabs separate; any other space, such as a no-break space,
///   is part of a key or value.
/// - A plain `true` or `false` is a boolean, `null` or `~` is null, and a
///   decimal integer is a number, as YAML reads them. A plain value that YAML
///   versions read differently (floats, `yes`, `0755`, dates) is refused.
///
/// The reader also keeps the block's boundaries, so MacRemote inserts its note
/// after the real closing line and renames a skill by replacing its `name`
/// entry, never by searching the text.
struct SkillFrontmatter: Equatable, Sendable {
    /// Why a header cannot be read exactly, as one sentence for the owner.
    struct Refusal: Error, Equatable, Sendable {
        let reason: String
    }

    let fields: [String: JSONValue]
    /// Where the line after the closing `---` starts.
    let bodyStart: String.Index
    /// The closing line's own line ending, used for inserted lines.
    let lineEnding: String
    /// The whole `name` entry, from its key to the end of its value.
    let nameEntry: Range<String.Index>?

    var name: String? {
        if case .string(let name) = fields["name"] { return name }
        return nil
    }

    var description: String? {
        if case .string(let description) = fields["description"] { return description }
        return nil
    }

    // MARK: Edits

    /// `text` with `paragraph` as the first paragraph after the block.
    /// `text` must be the text this header was read from.
    func insertingParagraph(_ paragraph: String, into text: String) -> String {
        var head = String(text[..<bodyStart])
        let body = text[bodyStart...]
        // By byte: Swift reads `\r\n` as one Character, which is not "\n".
        if head.utf8.last != UInt8(ascii: "\n") {
            head += lineEnding
        }
        let separator = body.utf8.first == UInt8(ascii: "\n") || body.hasPrefix("\r\n") ? "" : lineEnding
        return head + lineEnding + paragraph + lineEnding + separator + body
    }

    /// `text` with its `name` entry replaced by `name: <name>`, or nil when
    /// the header has none. `text` must be the text this header was read from.
    func renaming(_ text: String, to name: String) -> String? {
        guard let nameEntry else { return nil }
        return text.replacingCharacters(in: nameEntry, with: "name: \(name)")
    }

    // MARK: Reading

    /// Reads the frontmatter at the start of `text`.
    static func parse(_ text: String) -> Result<SkillFrontmatter, Refusal> {
        let lines = Line.split(text)
        guard let opening = lines.first, opening.isDelimiter else {
            return .failure(Refusal(reason: "It has no header."))
        }
        guard let closingIndex = lines.indices.dropFirst().first(where: { lines[$0].isDelimiter }) else {
            return .failure(Refusal(reason: "Its header never ends."))
        }
        let block = Array(lines[1..<closingIndex])
        if let lone = block.first(where: { $0.text.contains("\r") }) {
            return .failure(unreadable(lone))
        }
        do {
            let (fields, nameEntry) = try readEntries(block)
            let closing = lines[closingIndex]
            return .success(SkillFrontmatter(
                fields: fields,
                bodyStart: closing.end,
                lineEnding: closing.hasCRLF ? "\r\n" : "\n",
                nameEntry: nameEntry
            ))
        } catch let refusal as Refusal {
            return .failure(refusal)
        } catch {
            return .failure(Refusal(reason: "Its header can't be read."))
        }
    }

    private static func readEntries(_ block: [Line]) throws -> ([String: JSONValue], Range<String.Index>?) {
        var fields = [String: JSONValue]()
        var nameEntry: Range<String.Index>?
        var index = 0
        while index < block.count {
            let line = block[index]
            if line.isBlank || line.isComment {
                index += 1
                continue
            }
            guard !line.isIndented else { throw unreadable(line) }
            let (key, rest) = try splitEntry(line)
            guard fields[key] == nil else {
                throw Refusal(reason: "Its header names \(key) twice.")
            }
            // The entry's value may continue on the indented and blank lines below.
            var end = index + 1
            while end < block.count, block[end].isBlank || block[end].isIndented {
                end += 1
            }
            let children = Array(block[(index + 1)..<end])
            fields[key] = try value(after: rest, children: children, line: line)
            if key == "name" {
                let last = children.last { !$0.isBlank } ?? line
                nameEntry = line.start..<last.contentEnd
            }
            index = end
        }
        return (fields, nameEntry)
    }

    private static func value(after rest: Substring, children: [Line], line: Line) throws -> JSONValue {
        let header = rest.drop { $0 == " " || $0 == "\t" }
        if let style = header.first, style == "|" || style == ">" {
            return .string(try blockScalar(header: header, children: children, line: line))
        }
        let meaningful = children.filter { !$0.isBlank && !$0.isComment }
        if let scalar = try scalar(header, line: line) {
            // A plain or quoted value that runs on below is outside the subset.
            guard meaningful.isEmpty else { throw unreadable(meaningful[0]) }
            return scalar
        }
        guard !meaningful.isEmpty else {
            throw Refusal(reason: "Line \(line.number) of its header has no value.")
        }
        return .object(try stringMap(meaningful))
    }

    /// One level of `key: value` lines with text values, all at one indent
    /// of spaces. YAML never indents with a tab.
    private static func stringMap(_ lines: [Line]) throws -> [String: JSONValue] {
        let indent = lines[0].indent
        var map = [String: JSONValue]()
        for line in lines {
            guard indent > 0, line.indent == indent, line.text.dropFirst(indent).first != "\t" else {
                throw unreadable(line)
            }
            let (key, rest) = try splitEntry(line, from: line.text.dropFirst(indent))
            guard map[key] == nil else {
                throw Refusal(reason: "Its header names \(key) twice.")
            }
            guard case .string(let text)? = try scalar(rest.drop { $0 == " " || $0 == "\t" }, line: line) else {
                throw unreadable(line)
            }
            map[key] = .string(text)
        }
        return map
    }

    // MARK: Keys

    /// The key and what follows its colon. A plain key ends at the first colon
    /// followed by a space, a tab, or the end of the line.
    private static func splitEntry(_ line: Line, from start: Substring? = nil) throws -> (String, Substring) {
        let text = start ?? line.text
        guard let first = text.first else { throw unreadable(line) }
        if first == "\"" || first == "'" {
            guard let (key, afterKey) = quoted(text) else { throw unreadable(line) }
            let rest = afterKey.drop { $0 == " " || $0 == "\t" }
            guard rest.first == ":", rest.dropFirst().first.map({ $0 == " " || $0 == "\t" }) ?? true else {
                throw unreadable(line)
            }
            return (key, rest.dropFirst())
        }
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor] == ":" {
                let next = text.index(after: cursor)
                if next == text.endIndex || text[next] == " " || text[next] == "\t" {
                    let key = trimmingSeparators(text[..<cursor])
                    guard !key.isEmpty, isPlainKey(key) else { throw unreadable(line) }
                    return (key, text[next...])
                }
            }
            cursor = text.index(after: cursor)
        }
        throw unreadable(line)
    }

    private static func isPlainKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first) || first == "_" else { return false }
        return !key.contains { "#'\"{}[],&*!|>%@`".contains($0) }
    }

    // MARK: Scalars

    /// A one-line scalar, or nil when the value is empty (a comment alone
    /// counts as empty).
    private static func scalar(_ value: Substring, line: Line) throws -> JSONValue? {
        guard let first = value.first, first != "#" else { return nil }
        if first == "\"" || first == "'" {
            guard let (text, after) = quoted(value), isEndOfValue(after) else { throw unreadable(line) }
            return .string(text)
        }
        // Indicators that start something other than a plain scalar.
        if "[]{}&*!|>%@`,".contains(first) { throw unreadable(line) }
        if "-?:".contains(first), value.dropFirst().first.map({ $0 == " " || $0 == "\t" }) ?? true {
            throw unreadable(line)
        }
        var plain = value
        if let comment = plain.indices.first(where: { index in
            plain[index] == "#" && index > plain.startIndex
                && (plain[plain.index(before: index)] == " " || plain[plain.index(before: index)] == "\t")
        }) {
            plain = plain[..<comment]
        }
        let text = trimmingSeparators(plain)
        if text.contains(": ") || text.contains(":\t") || text.hasSuffix(":") {
            throw unreadable(line)
        }
        return try resolved(text, line: line)
    }

    /// `text` without the spaces and tabs around it. YAML separates with
    /// those two alone, so any other space (a no-break space) is text.
    private static func trimmingSeparators(_ text: Substring) -> String {
        let isSeparator: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        return String(text.drop(while: isSeparator).reversed().drop(while: isSeparator).reversed())
    }

    /// A plain scalar as YAML types it, refusing the forms YAML versions disagree on.
    private static func resolved(_ text: String, line: Line) throws -> JSONValue {
        switch text {
        case "true", "True", "TRUE":
            return .bool(true)
        case "false", "False", "FALSE":
            return .bool(false)
        case "null", "Null", "NULL", "~":
            return .null
        case "yes", "Yes", "YES", "no", "No", "NO", "on", "On", "ON", "off", "Off", "OFF", "y", "Y", "n", "N":
            throw unreadable(line)
        default:
            break
        }
        if text.wholeMatch(of: /[-+]?(0|[1-9][0-9]{0,14})/) != nil, let number = Double(text) {
            return .number(number)
        }
        let numberLike = text.wholeMatch(of: /[-+]?(\.[0-9]+|[0-9][0-9_]*(\.[0-9_]*)?)([eE][-+]?[0-9]+)?/) != nil
            || text.wholeMatch(of: /[-+]?\.(inf|Inf|INF)|\.(nan|NaN|NAN)/) != nil
            || text.wholeMatch(of: /[-+]?0([xX][0-9a-fA-F_]+|[oO][0-7_]+|[bB][01_]+)/) != nil
            || text.wholeMatch(of: /[-+]?[0-9][0-9_]*(:[0-5]?[0-9])+(\.[0-9_]*)?/) != nil
            // A date or timestamp as YAML 1.1 reads it; a date followed by
            // other words is text.
            || text.wholeMatch(
                of: /[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(([Tt]|[ \t]+)[0-9]{1,2}:[0-9]{2}:[0-9]{2}(\.[0-9]*)?([ \t]*(Z|[-+][0-9]{1,2}(:[0-9]{2})?))?)?/
            ) != nil
        if numberLike { throw unreadable(line) }
        return .string(text)
    }

    /// A quoted scalar at the start of `value` and what follows it, or nil
    /// when it does not close on this line or uses an escape outside the subset.
    private static func quoted(_ value: Substring) -> (String, Substring)? {
        guard let quote = value.first else { return nil }
        var result = String.UnicodeScalarView()
        var scalars = value.unicodeScalars.dropFirst()
        while let scalar = scalars.first {
            scalars = scalars.dropFirst()
            if quote == "'" {
                if scalar == "'" {
                    guard scalars.first == "'" else { return (String(result), Substring(scalars)) }
                    scalars = scalars.dropFirst()
                }
                result.append(scalar)
                continue
            }
            if scalar == "\"" { return (String(result), Substring(scalars)) }
            guard scalar == "\\" else {
                result.append(scalar)
                continue
            }
            guard let escape = scalars.first else { return nil }
            scalars = scalars.dropFirst()
            let simple: [Unicode.Scalar: Unicode.Scalar] = [
                "\\": "\\", "\"": "\"", "/": "/", "n": "\n", "t": "\t", "\t": "\t",
                "r": "\r", "0": "\0", "b": "\u{08}", "f": "\u{0C}", " ": " "
            ]
            if let replacement = simple[escape] {
                result.append(replacement)
                continue
            }
            let lengths: [Unicode.Scalar: Int] = ["x": 2, "u": 4, "U": 8]
            guard let digits = lengths[escape], scalars.count >= digits,
                  scalars.prefix(digits).allSatisfy(\.properties.isASCIIHexDigit),
                  let code = UInt32(String(String.UnicodeScalarView(scalars.prefix(digits))), radix: 16),
                  let decoded = Unicode.Scalar(code) else { return nil }
            scalars = scalars.dropFirst(digits)
            result.append(decoded)
        }
        return nil
    }

    /// Nothing but spaces, or spaces and a comment, follows a quoted value.
    private static func isEndOfValue(_ rest: Substring) -> Bool {
        let trimmed = rest.drop { $0 == " " || $0 == "\t" }
        return trimmed.isEmpty || (trimmed.first == "#" && trimmed.startIndex != rest.startIndex)
    }

    // MARK: Block scalars

    /// A `|` (literal) or `>` (folded) block scalar. Its content is every
    /// following line indented at least as far as its first non-empty line,
    /// whose indent must be spaces: YAML readers refuse a tab there.
    private static func blockScalar(header: Substring, children: [Line], line: Line) throws -> String {
        let isFolded = header.first == ">"
        var indicator = header.dropFirst()
        var chomping: Character?
        if let first = indicator.first, first == "-" || first == "+" {
            chomping = first
            indicator = indicator.dropFirst()
        }
        guard isEndOfValue(indicator) || indicator.isEmpty else { throw unreadable(line) }

        let texts = children.map { String($0.text) }
        let isEmpty: (String) -> Bool = { $0.allSatisfy { $0 == " " } }
        guard let firstContent = texts.firstIndex(where: { !isEmpty($0) }) else {
            throw Refusal(reason: "Line \(line.number) of its header has no value.")
        }
        let indent = texts[firstContent].prefix { $0 == " " }.count
        guard indent > 0, texts[firstContent].dropFirst(indent).first != "\t" else {
            throw unreadable(children[firstContent])
        }
        var content = [String?]()
        for (offset, text) in texts.enumerated() {
            if isEmpty(text) {
                if text.count <= indent {
                    content.append(nil)
                } else if !isFolded, offset > firstContent {
                    // Spaces past the indent are text in a literal block.
                    content.append(String(text.dropFirst(indent)))
                } else {
                    throw unreadable(children[offset])
                }
                continue
            }
            guard text.prefix(indent).allSatisfy({ $0 == " " }) else {
                throw unreadable(children[offset])
            }
            let body = String(text.dropFirst(indent))
            // A folded line that starts with white space keeps its line
            // breaks in YAML; that rule is outside the subset.
            if isFolded, let first = body.first, first == " " || first == "\t" {
                throw unreadable(children[offset])
            }
            content.append(body)
        }

        let lastContent = content.lastIndex { $0 != nil } ?? 0
        let trailingEmpty = content.count - lastContent - 1
        let lines = content[...lastContent]
        var value: String
        if isFolded {
            value = ""
            var pendingBreaks = 0
            var started = false
            for line in lines {
                guard let line else {
                    pendingBreaks += 1
                    continue
                }
                if started {
                    value += pendingBreaks == 0 ? " " : String(repeating: "\n", count: pendingBreaks)
                } else {
                    value += String(repeating: "\n", count: pendingBreaks)
                    started = true
                }
                pendingBreaks = 0
                value += line
            }
        } else {
            value = lines.map { $0 ?? "" }.joined(separator: "\n")
        }
        switch chomping {
        case "-": return value
        case "+": return value + "\n" + String(repeating: "\n", count: trailingEmpty)
        default: return value + "\n"
        }
    }

    private static func unreadable(_ line: Line) -> Refusal {
        Refusal(reason: "Line \(line.number) of its header uses YAML that MacRemote doesn't read.")
    }
}

/// One line of a SKILL.md, without its line ending.
private struct Line {
    let start: String.Index
    let contentEnd: String.Index
    let end: String.Index
    let text: Substring
    /// 1-based, counting the opening `---` as line 1.
    let number: Int
    let hasCRLF: Bool

    var isDelimiter: Bool {
        text.hasPrefix("---") && text.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" }
    }

    var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" } }

    var isComment: Bool { text.drop { $0 == " " || $0 == "\t" }.first == "#" }

    var isIndented: Bool { text.first == " " || text.first == "\t" }

    var indent: Int { text.prefix { $0 == " " }.count }

    /// Splits on `\n` in the UTF-8 bytes, dropping a `\r` before it, so a
    /// `\r\n` pair (one Character in Swift) still ends a line.
    static func split(_ text: String) -> [Line] {
        var lines = [Line]()
        let utf8 = text.utf8
        var start = utf8.startIndex
        while start < utf8.endIndex {
            let newline = utf8[start...].firstIndex(of: UInt8(ascii: "\n"))
            let end = newline.map { utf8.index(after: $0) } ?? utf8.endIndex
            var contentEnd = newline ?? utf8.endIndex
            var hasCRLF = false
            if let newline, newline > start, utf8[utf8.index(before: newline)] == UInt8(ascii: "\r") {
                contentEnd = utf8.index(before: newline)
                hasCRLF = true
            }
            lines.append(Line(
                start: start,
                contentEnd: contentEnd,
                end: end,
                text: text[start..<contentEnd],
                number: lines.count + 1,
                hasCRLF: hasCRLF
            ))
            start = end
        }
        return lines
    }
}
