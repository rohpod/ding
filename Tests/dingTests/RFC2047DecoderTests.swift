import XCTest
@testable import ding

final class RFC2047DecoderTests: XCTestCase {
    private func base64Word(_ text: String, charset: String = "UTF-8") -> String {
        "=?\(charset)?B?\(Data(text.utf8).base64EncodedString())?="
    }

    func testPlainTextIsReturnedUnchanged() {
        XCTAssertEqual(RFC2047Decoder.decode("Quarterly report"), "Quarterly report")
        XCTAssertEqual(RFC2047Decoder.decode(""), "")
        XCTAssertEqual(RFC2047Decoder.decode("Is 1 = 2 ? maybe =? not a word"), "Is 1 = 2 ? maybe =? not a word")
    }

    func testBase64Utf8WithAccentsAndEmoji() {
        XCTAssertEqual(RFC2047Decoder.decode(base64Word("héllo 👋")), "héllo 👋")
    }

    func testQuotedPrintableLatin1() {
        XCTAssertEqual(RFC2047Decoder.decode("=?ISO-8859-1?Q?caf=E9?="), "café")
    }

    func testQuotedPrintableUtf8AndUnderscoreAsSpace() {
        XCTAssertEqual(RFC2047Decoder.decode("=?UTF-8?Q?h=C3=A9llo_world?="), "héllo world")
    }

    func testEncodingAndCharsetAreCaseInsensitive() {
        XCTAssertEqual(RFC2047Decoder.decode("=?utf-8?b?\(Data("ok".utf8).base64EncodedString())?="), "ok")
        XCTAssertEqual(RFC2047Decoder.decode("=?iso-8859-1?q?caf=e9?="), "café")
    }

    func testSurroundingTextIsPreserved() {
        let input = "Re: \(base64Word("Résumé")) attached (2)"
        XCTAssertEqual(RFC2047Decoder.decode(input), "Re: Résumé attached (2)")
    }

    func testWhitespaceBetweenAdjacentWordsIsDropped() {
        let input = "\(base64Word("Hello, ")) \(base64Word("wörld"))"
        XCTAssertEqual(RFC2047Decoder.decode(input), "Hello, wörld")
    }

    func testMultiByteCharacterSplitAcrossWordsIsRepaired() {
        // "é" is C3 A9 in UTF-8; a sender split the two bytes into separate words.
        XCTAssertEqual(RFC2047Decoder.decode("=?UTF-8?Q?caf=C3?= =?UTF-8?Q?=A9?="), "café")
    }

    func testNonAdjacentWordsKeepTheirSeparator() {
        let input = "\(base64Word("Ünï")) and \(base64Word("cödé"))"
        XCTAssertEqual(RFC2047Decoder.decode(input), "Ünï and cödé")
    }

    func testLanguageSuffixOnCharsetIsIgnored() {
        XCTAssertEqual(RFC2047Decoder.decode("=?UTF-8*en?Q?h=C3=A9llo?="), "héllo")
    }

    func testUnpaddedBase64IsAccepted() {
        let unpadded = Data("é".utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(RFC2047Decoder.decode("=?UTF-8?B?\(unpadded)?="), "é")
    }

    func testUndecodableWordsAreLeftAsIs() {
        XCTAssertEqual(RFC2047Decoder.decode("=?NOT-A-CHARSET?B?aGk=?="), "=?NOT-A-CHARSET?B?aGk=?=")
        XCTAssertEqual(RFC2047Decoder.decode("=?UTF-8?B?!!!not base64!!!?="), "=?UTF-8?B?!!!not base64!!!?=")
        XCTAssertEqual(RFC2047Decoder.decode("=?UTF-8?Q?bad=ZZescape?="), "=?UTF-8?Q?bad=ZZescape?=")
        XCTAssertEqual(RFC2047Decoder.decode("=?UTF-8?Q?truncated=C?="), "=?UTF-8?Q?truncated=C?=")
    }

    func testOneBadWordDoesNotSpoilItsNeighbours() {
        let input = "=?NOT-A-CHARSET?B?aGk=?= then \(base64Word("fine"))"
        XCTAssertEqual(RFC2047Decoder.decode(input), "=?NOT-A-CHARSET?B?aGk=?= then fine")
    }

    func testDecodedSenderStillFormatsForNotification() {
        let from = "\(base64Word("José Müller")) <jose@example.com>"
        XCTAssertEqual(NotificationContentBuilder.formatSender(RFC2047Decoder.decode(from)), "José Müller")
    }
}
