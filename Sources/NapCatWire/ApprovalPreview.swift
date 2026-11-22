// NapCatWire — F4 remote approvals: the strict reader for a permission
// prompt's input preview (the tool's arguments as JSON text). Design:
// design/remote-approvals.md.
//
// PURE — no imports, no I/O, no clock. The gate (ApprovalClassification.swift)
// classifies only what this reader returns, so it refuses everything a
// different reader could understand differently: a preview it rejects is
// never forwarded (fail closed).

/// One JSON value of an input preview.
indirect enum PreviewValue: Equatable, Sendable {
    case string(String)
    /// The literal number text, already checked against the JSON grammar.
    case number(String)
    case bool(Bool)
    case null
    case array([PreviewValue])
    case object([PreviewMember])
}

/// One member of a JSON object, in document order.
struct PreviewMember: Equatable, Sendable {
    let key: String
    let value: PreviewValue
}

/// RFC 8259 JSON with every ambiguity refused. Only a top-level OBJECT is a
/// preview. Refused: a duplicate key at any depth, a NUL or an unpaired
/// surrogate escape, a raw control character in a string, a number outside
/// the JSON grammar (leading zeros, `+1`, `.5`, `1.`) or longer than
/// `maxNumberBytes`, nesting deeper than `maxDepth`, a byte order mark, and
/// anything after the object but whitespace.
enum ApprovalPreview {
    static let maxDepth = 16
    static let maxNumberBytes = 32

    /// The top-level object's members, or nil when `text` is not exactly one
    /// strict JSON object.
    static func parseObject(_ text: String) -> [PreviewMember]? {
        var reader = PreviewReader(bytes: Array(text.utf8))
        reader.skipWhitespace()
        guard case .object(let members)? = reader.value(depth: 0) else { return nil }
        reader.skipWhitespace()
        return reader.atEnd ? members : nil
    }

    /// Every string in `members`, keys included, at every depth.
    static func strings(in members: [PreviewMember]) -> [String] {
        members.flatMap { [$0.key] + strings(in: $0.value) }
    }

    private static func strings(in value: PreviewValue) -> [String] {
        switch value {
        case .string(let text): return [text]
        case .array(let items): return items.flatMap { strings(in: $0) }
        case .object(let members): return strings(in: members)
        case .number, .bool, .null: return []
        }
    }
}

/// A one-pass recursive-descent reader over UTF-8 bytes. The bytes come from
/// a Swift String, so they are valid UTF-8; escapes are re-encoded here.
private struct PreviewReader {
    let bytes: [UInt8]
    var index = 0

    init(bytes: [UInt8]) { self.bytes = bytes }

    var atEnd: Bool { index == bytes.count }

    private func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
    }

    private mutating func expect(_ literal: String) -> Bool {
        let wanted = Array(literal.utf8)
        guard index + wanted.count <= bytes.count, Array(bytes[index..<index + wanted.count]) == wanted else { return false }
        index += wanted.count
        return true
    }

    mutating func value(depth: Int) -> PreviewValue? {
        guard depth <= ApprovalPreview.maxDepth, let byte = peek() else { return nil }
        switch byte {
        case UInt8(ascii: "{"): return object(depth: depth)
        case UInt8(ascii: "["): return array(depth: depth)
        case UInt8(ascii: "\""): return string().map { .string($0) }
        case UInt8(ascii: "t"): return expect("true") ? .bool(true) : nil
        case UInt8(ascii: "f"): return expect("false") ? .bool(false) : nil
        case UInt8(ascii: "n"): return expect("null") ? .null : nil
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return number()
        default: return nil
        }
    }

    private mutating func object(depth: Int) -> PreviewValue? {
        index += 1
        var members: [PreviewMember] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\""), let key = string() else { return nil }
            guard !members.contains(where: { $0.key == key }) else { return nil }
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { return nil }
            index += 1
            skipWhitespace()
            guard let value = value(depth: depth + 1) else { return nil }
            members.append(PreviewMember(key: key, value: value))
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ",")?: index += 1
            case UInt8(ascii: "}")?: index += 1; return .object(members)
            default: return nil
            }
        }
    }

    private mutating func array(depth: Int) -> PreviewValue? {
        index += 1
        var items: [PreviewValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            guard let item = value(depth: depth + 1) else { return nil }
            items.append(item)
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ",")?: index += 1
            case UInt8(ascii: "]")?: index += 1; return .array(items)
            default: return nil
            }
        }
    }

    private mutating func hexQuad() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for byte in bytes[index..<index + 4] {
            let digit: UInt8
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = byte - UInt8(ascii: "A") + 10
            default: return nil
            }
            value = value << 4 | UInt32(digit)
        }
        index += 4
        return value
    }

    /// A string at the opening quote, decoded, or nil.
    private mutating func string() -> String? {
        index += 1
        var out: [UInt8] = []
        while let byte = peek() {
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: out, as: UTF8.self)
            case 0x00..<0x20:
                return nil
            case UInt8(ascii: "\\"):
                guard let escape = peek() else { return nil }
                index += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard var code = hexQuad() else { return nil }
                    if (0xD800...0xDBFF).contains(code) {
                        guard expect("\\u"), let low = hexQuad(), (0xDC00...0xDFFF).contains(low) else { return nil }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard code != 0, let scalar = Unicode.Scalar(code) else { return nil }
                    UTF8.encode(scalar) { out.append($0) }
                default:
                    return nil
                }
            default:
                out.append(byte)
            }
        }
        return nil
    }

    private mutating func digits() -> Int {
        let start = index
        while let byte = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
        return index - start
    }

    /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`
    private mutating func number() -> PreviewValue? {
        let start = index
        if peek() == UInt8(ascii: "-") { index += 1 }
        if peek() == UInt8(ascii: "0") {
            index += 1
        } else {
            guard digits() > 0 else { return nil }
        }
        if peek() == UInt8(ascii: ".") {
            index += 1
            guard digits() > 0 else { return nil }
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            index += 1
            if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { return nil }
        }
        guard index - start <= ApprovalPreview.maxNumberBytes else { return nil }
        return .number(String(decoding: bytes[start..<index], as: UTF8.self))
    }
}
