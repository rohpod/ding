import Foundation

/// Decodes RFC 2047 "encoded-words" found in message headers, such as `=?UTF-8?B?...?=` or `=?ISO-8859-1?Q?caf=E9?=`.
///
/// IMAP servers return the `Subject` and display names in `ENVELOPE` exactly as they appear in the message
/// header, so any non-ASCII text arrives encoded. Without decoding, notifications would show the raw
/// `=?UTF-8?...?=` syntax instead of the real text.
///
/// Decoding never throws: anything that cannot be decoded (unknown charset, corrupt payload) is left as the
/// original text so a notification is still shown.
enum RFC2047Decoder {
    private static let pattern = try? NSRegularExpression(
        pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?\s]*)\?="#
    )

    private struct Token {
        let range: Range<String.Index>
        let original: String
        let charset: String
        let bytes: Data?
    }

    /// Returns `input` with every valid encoded-word replaced by its decoded text.
    static func decode(_ input: String) -> String {
        guard input.contains("=?"), let pattern else { return input }

        let fullRange = NSRange(input.startIndex..., in: input)
        let tokens: [Token] = pattern.matches(in: input, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: input),
                  let charsetRange = Range(match.range(at: 1), in: input),
                  let encodingRange = Range(match.range(at: 2), in: input),
                  let payloadRange = Range(match.range(at: 3), in: input) else { return nil }

            // RFC 2231 allows a language suffix after the charset ("UTF-8*en").
            let charset = String(input[charsetRange]).split(separator: "*", maxSplits: 1).first.map(String.init) ?? ""
            let payload = String(input[payloadRange])
            let bytes: Data?
            switch input[encodingRange].lowercased() {
            case "b": bytes = decodeBase64(payload)
            default: bytes = decodeQ(payload)
            }
            return Token(range: range, original: String(input[range]), charset: charset, bytes: bytes)
        }
        guard !tokens.isEmpty else { return input }

        var output = ""
        var cursor = input.startIndex
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            output += input[cursor..<token.range.lowerBound]

            // Adjacent encoded-words (separated only by whitespace) form one logical run, and the whitespace
            // between them is not part of the text. Merging bytes first also repairs multi-byte characters
            // that a sender split across two words.
            var run = [token]
            var end = token.range.upperBound
            while index + 1 < tokens.count {
                let next = tokens[index + 1]
                let gap = input[end..<next.range.lowerBound]
                guard gap.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }) else { break }
                run.append(next)
                end = next.range.upperBound
                index += 1
            }

            output += decodeRun(run, source: input, from: token.range.lowerBound, to: end)
            cursor = end
            index += 1
        }

        output += input[cursor...]
        return output
    }

    /// Decodes a run of adjacent encoded-words, merging consecutive words that share a charset.
    private static func decodeRun(_ run: [Token], source: String, from: String.Index, to: String.Index) -> String {
        var result = ""
        var position = 0
        while position < run.count {
            let first = run[position]
            var merged = Data()
            var originals = ""
            var valid = first.bytes != nil
            var next = position

            while next < run.count, run[next].charset.lowercased() == first.charset.lowercased() {
                if let bytes = run[next].bytes { merged.append(bytes) } else { valid = false }
                originals += run[next].original
                next += 1
            }

            if valid, let text = string(from: merged, charset: first.charset) {
                result += text
            } else {
                // Leave undecodable words untouched rather than dropping the user's subject text.
                result += originals
            }
            position = next
        }
        return result
    }

    private static func decodeBase64(_ payload: String) -> Data? {
        var padded = payload
        while padded.count % 4 != 0 { padded += "=" }
        return Data(base64Encoded: padded)
    }

    /// Decodes the "Q" encoding: `_` is a space and `=XX` is a hex-escaped byte.
    private static func decodeQ(_ payload: String) -> Data? {
        var data = Data()
        let bytes = Array(payload.utf8)
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case UInt8(ascii: "_"):
                data.append(0x20)
                i += 1
            case UInt8(ascii: "="):
                guard i + 2 < bytes.count else { return nil }
                guard let high = hexValue(bytes[i + 1]), let low = hexValue(bytes[i + 2]) else { return nil }
                data.append(UInt8(high << 4 | low))
                i += 3
            default:
                data.append(bytes[i])
                i += 1
            }
        }
        return data
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return Int(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return Int(byte - UInt8(ascii: "A")) + 10
        default: return nil
        }
    }

    private static func string(from data: Data, charset: String) -> String? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        return String(data: data, encoding: encoding)
    }
}
