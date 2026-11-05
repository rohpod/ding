import XCTest
@testable import ding

final class MailProviderTests: XCTestCase {
    func testMailProviderPresets() {
        // Gmail
        XCTAssertEqual(MailProvider.gmail.displayName, "Gmail")
        XCTAssertEqual(MailProvider.gmail.presetServer?.host, "imap.gmail.com")
        XCTAssertEqual(MailProvider.gmail.presetServer?.port, 993)
        XCTAssertEqual(MailProvider.gmail.appPasswordURL?.absoluteString, "https://myaccount.google.com/apppasswords")

        // iCloud
        XCTAssertEqual(MailProvider.icloud.displayName, "iCloud")
        XCTAssertEqual(MailProvider.icloud.presetServer?.host, "imap.mail.me.com")
        XCTAssertEqual(MailProvider.icloud.presetServer?.port, 993)
        XCTAssertEqual(MailProvider.icloud.appPasswordURL?.absoluteString, "https://appleid.apple.com/account/manage")

        // Outlook
        XCTAssertEqual(MailProvider.outlook.displayName, "Outlook")
        XCTAssertEqual(MailProvider.outlook.presetServer?.host, "outlook.office365.com")
        XCTAssertEqual(MailProvider.outlook.presetServer?.port, 993)
        XCTAssertEqual(MailProvider.outlook.appPasswordURL?.absoluteString, "https://account.live.com/proofs/AppPassword")

        // Yahoo
        XCTAssertEqual(MailProvider.yahoo.displayName, "Yahoo")
        XCTAssertEqual(MailProvider.yahoo.presetServer?.host, "imap.mail.yahoo.com")
        XCTAssertEqual(MailProvider.yahoo.presetServer?.port, 993)
        XCTAssertEqual(MailProvider.yahoo.appPasswordURL?.absoluteString, "https://login.yahoo.com/myaccount/security")

        // Fastmail
        XCTAssertEqual(MailProvider.fastmail.displayName, "Fastmail")
        XCTAssertEqual(MailProvider.fastmail.presetServer?.host, "imap.fastmail.com")
        XCTAssertEqual(MailProvider.fastmail.presetServer?.port, 993)
        XCTAssertEqual(MailProvider.fastmail.appPasswordURL?.absoluteString, "https://app.fastmail.com/settings/security/apppasswords")
    }

    func testMailProviderDomains() {
        XCTAssertEqual(MailProvider.gmail.domains, ["gmail.com", "googlemail.com"])
        XCTAssertEqual(MailProvider.icloud.domains, ["icloud.com", "me.com", "mac.com"])
        XCTAssertEqual(MailProvider.outlook.domains, ["outlook.com", "hotmail.com", "live.com", "msn.com"])
        XCTAssertEqual(MailProvider.yahoo.domains, ["yahoo.com", "ymail.com"])
        XCTAssertEqual(MailProvider.fastmail.domains, ["fastmail.com"])
    }

    func testMailProviderDetectionValid() {
        // Gmail & Googlemail
        XCTAssertEqual(MailProvider.detect(fromEmail: "user@gmail.com"), .gmail)
        XCTAssertEqual(MailProvider.detect(fromEmail: "user@googlemail.com"), .gmail)

        // iCloud, Me, Mac
        XCTAssertEqual(MailProvider.detect(fromEmail: "user@icloud.com"), .icloud)
        XCTAssertEqual(MailProvider.detect(fromEmail: "user@me.com"), .icloud)
        XCTAssertEqual(MailProvider.detect(fromEmail: "user@mac.com"), .icloud)

        // Outlook, Hotmail, Live, MSN
        XCTAssertEqual(MailProvider.detect(fromEmail: "user@outlook.com"), .outlook)
        XCTAssertEqual(MailProvider.detect(fromEmail: "user@hotmail.com"), .outlook)
        XCTAssertEqual(MailProvider.detect(fromEmail: "user@live.com"), .outlook)
        XCTAssertEqual(MailProvider.detect(fromEmail: "user@msn.com"), .outlook)

        // Yahoo, Ymail
        XCTAssertEqual(MailProvider.detect(fromEmail: "user@yahoo.com"), .yahoo)
        XCTAssertEqual(MailProvider.detect(fromEmail: "user@ymail.com"), .yahoo)

        // Fastmail
        XCTAssertEqual(MailProvider.detect(fromEmail: "user@fastmail.com"), .fastmail)
    }

    func testMailProviderDetectionCaseAndWhitespace() {
        XCTAssertEqual(MailProvider.detect(fromEmail: "USER@GMAIL.COM"), .gmail)
        XCTAssertEqual(MailProvider.detect(fromEmail: "  User@Outlook.Com  \n"), .outlook)
        XCTAssertEqual(MailProvider.detect(fromEmail: "my.name+tag@FastMail.com"), .fastmail)
    }

    func testMailProviderDetectionInvalidOrUnsupported() {
        // Unsupported custom domains
        XCTAssertNil(MailProvider.detect(fromEmail: "user@customdomain.org"))
        XCTAssertNil(MailProvider.detect(fromEmail: "user@company.co.uk"))

        // Malformed email inputs
        XCTAssertNil(MailProvider.detect(fromEmail: "invalid-email"))
        XCTAssertNil(MailProvider.detect(fromEmail: ""))
        XCTAssertNil(MailProvider.detect(fromEmail: "   "))
        XCTAssertNil(MailProvider.detect(fromEmail: "@gmail.com"))
        XCTAssertNil(MailProvider.detect(fromEmail: "user@"))
        XCTAssertNil(MailProvider.detect(fromEmail: "user@@gmail.com"))
        XCTAssertNil(MailProvider.detect(fromEmail: "user@subdomain.gmail.com"))
    }

    func testMailProviderCodable() throws {
        for provider in MailProvider.allCases {
            let encoded = try JSONEncoder().encode(provider)
            let decoded = try JSONDecoder().decode(MailProvider.self, from: encoded)
            XCTAssertEqual(decoded, provider)
        }
    }

    func testPresetsExcludeCustom() {
        XCTAssertEqual(MailProvider.presets, [.gmail, .icloud, .outlook, .yahoo, .fastmail])
        XCTAssertTrue(MailProvider.allCases.contains(.custom))
    }

    func testCustomProviderHasNoPresetServerPortalOrWebmail() {
        XCTAssertEqual(MailProvider.custom.displayName, "Other (IMAP)")
        XCTAssertNil(MailProvider.custom.presetServer, "A custom account must never connect to a placeholder")
        XCTAssertNil(MailProvider.custom.appPasswordURL)
        XCTAssertNil(MailProvider.custom.webmailURL)
        XCTAssertTrue(MailProvider.custom.domains.isEmpty)
    }

    func testDetectionNeverReturnsCustom() {
        XCTAssertNil(MailProvider.detect(fromEmail: "user@mycompany.com"))
        for provider in MailProvider.presets {
            for domain in provider.domains {
                XCTAssertEqual(MailProvider.detect(fromEmail: "user@\(domain)"), provider)
            }
        }
    }

    func testEveryPresetHasAServerAndLinks() {
        for provider in MailProvider.presets {
            XCTAssertNotNil(provider.presetServer)
            XCTAssertNotNil(provider.appPasswordURL)
            XCTAssertNotNil(provider.webmailURL)
        }
    }
}
