import Foundation
import UserNotifications
import XCTest
@testable import ding

final class NotificationServiceTests: XCTestCase {
    // MARK: - MailProvider Webmail URLs

    func testMailProviderWebmailURLs() {
        XCTAssertEqual(MailProvider.gmail.webmailURL?.absoluteString, "https://mail.google.com")
        XCTAssertEqual(MailProvider.icloud.webmailURL?.absoluteString, "https://www.icloud.com/mail")
        XCTAssertEqual(MailProvider.outlook.webmailURL?.absoluteString, "https://outlook.live.com/mail")
        XCTAssertEqual(MailProvider.yahoo.webmailURL?.absoluteString, "https://mail.yahoo.com")
        XCTAssertEqual(MailProvider.fastmail.webmailURL?.absoluteString, "https://app.fastmail.com")

        for provider in MailProvider.presets {
            XCTAssertEqual(provider.webmailURL?.absoluteString.isEmpty, false)
            XCTAssertNotNil(provider.webmailURL?.scheme)
            XCTAssertNotNil(provider.webmailURL?.host)
        }
        XCTAssertNil(MailProvider.custom.webmailURL)
        XCTAssertNil(MailProvider.custom.appPasswordURL)
    }

    // MARK: - Notification Content Formatting

    func testNotificationContentBuilderSingleMessageWithSenderAndSubject() {
        let account = Account(
            email: "user@example.com",
            provider: .gmail,
            alias: "Work Mail"
        )
        let message = MessageSummary(
            uid: 101,
            subject: "Quarterly Report",
            from: "Alice Smith <alice@example.com>",
            dateReceived: Date()
        )
        let event = NewMailEvent(accountID: account.id, messages: [message])

        let content = NotificationContentBuilder.buildContent(for: event, account: account)

        XCTAssertEqual(content.title, "Work Mail")
        XCTAssertEqual(content.body, "From: Alice Smith\nSub: Quarterly Report")
        XCTAssertEqual(content.sound, .default)

        guard let accountID = content.userInfo[NotificationUserInfoKey.accountID] as? String,
              let uids = content.userInfo[NotificationUserInfoKey.messageUIDs] as? [String] else {
            XCTFail("Missing or invalid userInfo keys")
            return
        }

        XCTAssertEqual(accountID, account.id.uuidString)
        XCTAssertEqual(uids, ["101"])
    }

    func testNotificationContentBuilderSingleMessageFallbacks() {
        let account = Account(
            email: "user@example.com",
            provider: .fastmail
        )

        // Title falls back to email when alias is nil
        XCTAssertEqual(account.displayName, "user@example.com")

        // Only subject provided
        let msgOnlySubject = MessageSummary(
            uid: 1,
            subject: "Meeting Tomorrow",
            from: "",
            dateReceived: Date()
        )
        let bodyOnlySubject = NotificationContentBuilder.formatBody(for: [msgOnlySubject])
        XCTAssertEqual(bodyOnlySubject, "Sub: Meeting Tomorrow")

        // Only sender provided
        let msgOnlySender = MessageSummary(
            uid: 2,
            subject: "",
            from: "Bob Jones",
            dateReceived: Date()
        )
        let bodyOnlySender = NotificationContentBuilder.formatBody(for: [msgOnlySender])
        XCTAssertEqual(bodyOnlySender, "From: Bob Jones")

        // Neither provided
        let msgEmpty = MessageSummary(
            uid: 3,
            subject: "",
            from: "",
            dateReceived: Date()
        )
        let bodyEmpty = NotificationContentBuilder.formatBody(for: [msgEmpty])
        XCTAssertEqual(bodyEmpty, "New message")

        // Empty array fallback
        let bodyNoMessages = NotificationContentBuilder.formatBody(for: [])
        XCTAssertEqual(bodyNoMessages, "New mail")
    }

    func testNotificationContentBuilderMultipleMessages() {
        let account = Account(
            email: "personal@icloud.com",
            provider: .icloud,
            alias: "Personal"
        )
        let messages = [
            MessageSummary(uid: 1, subject: "Hello", from: "Alice", dateReceived: Date()),
            MessageSummary(uid: 2, subject: "Hi", from: "Bob", dateReceived: Date()),
            MessageSummary(uid: 3, subject: "Hey", from: "Charlie", dateReceived: Date())
        ]
        let event = NewMailEvent(accountID: account.id, messages: messages)

        let content = NotificationContentBuilder.buildContent(for: event, account: account)

        XCTAssertEqual(content.title, "Personal")
        XCTAssertEqual(content.body, "3 new messages\nFrom: Charlie, Bob, Alice")
        XCTAssertEqual(content.sound, .default)
        XCTAssertEqual(content.threadIdentifier, NotificationContentBuilder.threadIdentifier(forAccountID: account.id))

        guard let uids = content.userInfo[NotificationUserInfoKey.messageUIDs] as? [String] else {
            XCTFail("Missing messageUIDs in userInfo")
            return
        }
        XCTAssertEqual(uids, ["1", "2", "3"])
    }

    func testNotificationContentBuilderZeroUnread() {
        let content = NotificationContentBuilder.buildZeroUnreadContent()
        XCTAssertEqual(content.title, "You have 0 unread emails")
        XCTAssertEqual(content.body, "")
        XCTAssertEqual(content.sound, .default)
    }

    func testNotificationContentBuilderAccountUnreadSingle() {
        let account = Account(email: "single@example.com", provider: .gmail, alias: "Work Mail")
        let content = NotificationContentBuilder.buildAccountUnreadContent(account: account, unreadCount: 1)

        XCTAssertEqual(content.title, "Work Mail")
        XCTAssertEqual(content.body, "1 unread email")
        XCTAssertEqual(content.sound, .default)
        XCTAssertEqual(content.userInfo[NotificationUserInfoKey.accountID] as? String, account.id.uuidString)
    }

    func testNotificationContentBuilderAccountUnreadMultiple() {
        let account = Account(email: "multi@example.com", provider: .fastmail, alias: "Fastmail")
        let content = NotificationContentBuilder.buildAccountUnreadContent(account: account, unreadCount: 12)

        XCTAssertEqual(content.title, "Fastmail")
        XCTAssertEqual(content.body, "12 unread emails")
        XCTAssertEqual(content.sound, .default)
        XCTAssertEqual(content.userInfo[NotificationUserInfoKey.accountID] as? String, account.id.uuidString)
    }

    func testNotificationContentBuilderAccountUnreadFallsBackToEmailWhenAliasNil() {
        let account = Account(email: "noalias@example.com", provider: .yahoo)
        let content = NotificationContentBuilder.buildAccountUnreadContent(account: account, unreadCount: 5)

        XCTAssertEqual(content.title, "noalias@example.com")
        XCTAssertEqual(content.body, "5 unread emails")
    }

    // MARK: - Notification Action Resolver Tests

    func testNotificationActionResolverWithUseDefault() {
        let defaultBehaviors: [NotificationClickBehavior] = [.openMailApp, .openInBrowser, .doNothing]

        for defaultBehavior in defaultBehaviors {
            let account = Account(
                email: "test@example.com",
                provider: .gmail,
                notificationClickBehavior: .useDefault
            )

            let resolved = NotificationActionResolver.resolveBehavior(
                for: account,
                defaultBehavior: defaultBehavior
            )
            XCTAssertEqual(resolved, defaultBehavior)
        }
    }

    func testNotificationActionResolverExplicitOverrides() {
        let accountMailApp = Account(
            email: "test@example.com",
            provider: .gmail,
            notificationClickBehavior: .openMailApp
        )
        let accountBrowser = Account(
            email: "test@example.com",
            provider: .outlook,
            notificationClickBehavior: .openInBrowser
        )
        let accountDoNothing = Account(
            email: "test@example.com",
            provider: .yahoo,
            notificationClickBehavior: .doNothing
        )

        // Regardless of fallback, explicit preference wins
        XCTAssertEqual(
            NotificationActionResolver.resolveBehavior(for: accountMailApp, defaultBehavior: .doNothing),
            .openMailApp
        )
        XCTAssertEqual(
            NotificationActionResolver.resolveBehavior(for: accountBrowser, defaultBehavior: .openMailApp),
            .openInBrowser
        )
        XCTAssertEqual(
            NotificationActionResolver.resolveBehavior(for: accountDoNothing, defaultBehavior: .openInBrowser),
            .doNothing
        )
    }

    // MARK: - Notification Action Router Tests

    func testNotificationActionRouterDoNothing() {
        var openedURLs: [URL] = []
        let result = NotificationActionRouter.execute(
            behavior: .doNothing,
            provider: .gmail,
            urlOpener: { url in
                openedURLs.append(url)
                return true
            }
        )

        XCTAssertFalse(result)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testNotificationActionRouterOpenInBrowser() {
        var openedURLs: [URL] = []
        let result = NotificationActionRouter.execute(
            behavior: .openInBrowser,
            provider: .gmail,
            urlOpener: { url in
                openedURLs.append(url)
                return true
            }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(openedURLs.count, 1)
        XCTAssertEqual(openedURLs.first, MailProvider.gmail.webmailURL)
    }

    func testNotificationActionRouterOpenInBrowserFallsBackToMailAppForCustomProvider() {
        var openedURLs: [URL] = []
        let expectedAppURL = URL(fileURLWithPath: "/System/Applications/Mail.app")
        let result = NotificationActionRouter.execute(
            behavior: .openInBrowser,
            provider: .custom,
            defaultMailAppURLResolver: { expectedAppURL },
            urlOpener: { url in
                openedURLs.append(url)
                return true
            }
        )

        XCTAssertTrue(result, "A custom server has no webmail, so the global browser default must not silently do nothing")
        XCTAssertEqual(openedURLs, [expectedAppURL])
    }

    func testNotificationActionRouterOpenMailApp() {
        var openedURLs: [URL] = []
        let expectedAppURL = URL(fileURLWithPath: "/System/Applications/Mail.app")
        let result = NotificationActionRouter.execute(
            behavior: .openMailApp,
            provider: .fastmail,
            defaultMailAppURLResolver: { expectedAppURL },
            urlOpener: { url in
                openedURLs.append(url)
                return true
            }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(openedURLs.count, 1)
        XCTAssertEqual(openedURLs.first, expectedAppURL)
    }

    func testNotificationActionRouterOpenMailAppMissingClient() {
        var openedURLs: [URL] = []
        let result = NotificationActionRouter.execute(
            behavior: .openMailApp,
            provider: .fastmail,
            defaultMailAppURLResolver: { nil },
            urlOpener: { url in
                openedURLs.append(url)
                return true
            }
        )

        XCTAssertFalse(result)
        XCTAssertTrue(openedURLs.isEmpty)
    }

    func testNotificationContentBuilderFormatSender() {
        XCTAssertEqual(
            NotificationContentBuilder.formatSender("Rohan Poddar <rohan07062004@gmail.com>"),
            "Rohan Poddar"
        )
        XCTAssertEqual(
            NotificationContentBuilder.formatSender("\"Jane Doe\" <jane@example.com>"),
            "Jane Doe"
        )
        XCTAssertEqual(
            NotificationContentBuilder.formatSender("<support@service.com>"),
            "support@service.com"
        )
        XCTAssertEqual(
            NotificationContentBuilder.formatSender("alerts@security.org"),
            "alerts@security.org"
        )
        XCTAssertEqual(
            NotificationContentBuilder.formatSender(""),
            ""
        )
    }

    func testNotificationContentBuilderFormatSubject() {
        // Short single-line subject
        XCTAssertEqual(NotificationContentBuilder.formatSubject("Re: test 2"), "Re: test 2")

        // 3-line subject passes intact
        let threeLines = "Line 1\nLine 2\nLine 3"
        XCTAssertEqual(NotificationContentBuilder.formatSubject(threeLines), "Line 1\nLine 2\nLine 3")

        // 4-line subject gets truncated after line 3 with ...
        let fourLines = "Line 1\nLine 2\nLine 3\nLine 4"
        XCTAssertEqual(NotificationContentBuilder.formatSubject(fourLines), "Line 1\nLine 2\nLine 3...")

        // Very long subject (> 150 characters) gets truncated with ...
        let longSubject = String(repeating: "A", count: 200)
        let formattedLong = NotificationContentBuilder.formatSubject(longSubject)
        XCTAssertEqual(formattedLong.count, 150)
        XCTAssertTrue(formattedLong.hasSuffix("..."))
    }

    // MARK: - Notification Service & Click Handler Concurrency & Safety

    @MainActor
    func testNotificationServiceOutsideAppBundleSafelyNoops() async {
        let service = NotificationService()

        // Calling in test runner (unbundled) must not throw or crash
        await service.requestPermissionIfNeeded()

        let account = Account(email: "test@example.com", provider: .gmail)
        let event = NewMailEvent(
            accountID: account.id,
            messages: [MessageSummary(uid: 1, subject: "Hi", from: "A", dateReceived: Date())]
        )
        await service.send(for: event, account: account)
    }

    func testReauthenticationContentIsTaggedSoClickOpensSettings() {
        let account = Account(email: "x@gmail.com", provider: .gmail, alias: "Work")
        let content = NotificationContentBuilder.buildReauthenticationContent(account: account)

        XCTAssertEqual(content.title, "Work")
        XCTAssertTrue(content.body.contains("app password"))
        XCTAssertEqual(content.userInfo[NotificationUserInfoKey.accountID] as? String, account.id.uuidString)
        XCTAssertEqual(content.userInfo[NotificationUserInfoKey.kind] as? String, NotificationUserInfoKey.reauthenticationKind)
        XCTAssertEqual(content.threadIdentifier, "", "A sign-in alert must not fold into the mail stack")

        let ordinary = NotificationContentBuilder.buildContent(
            for: NewMailEvent(accountID: account.id, messages: []), account: account
        )
        XCTAssertNil(ordinary.userInfo[NotificationUserInfoKey.kind], "Ordinary mail notifications keep their click behaviour")
    }

    func testCheckFailedContentPluralisation() {
        XCTAssertTrue(NotificationContentBuilder.buildCheckFailedContent(failedCount: 1).body.contains("1 account."))
        XCTAssertTrue(NotificationContentBuilder.buildCheckFailedContent(failedCount: 3).body.contains("3 accounts"))
    }

    // MARK: - Grouped notifications

    private func batch(_ senders: [String]) -> [MessageSummary] {
        senders.enumerated().map { index, from in
            MessageSummary(uid: UInt32(index + 1), subject: "S", from: from, dateReceived: Date())
        }
    }

    func testMultiMessageBodyListsSendersNewestFirst() {
        XCTAssertEqual(
            NotificationContentBuilder.formatBody(for: batch(["Alice", "Bob", "Charlie"])),
            "3 new messages\nFrom: Charlie, Bob, Alice"
        )
    }

    func testMultiMessageBodyDedupesCaseInsensitivelyNewestCasingWins() {
        XCTAssertEqual(
            NotificationContentBuilder.formatBody(for: batch(["Alice", "Alice", "alice"])),
            "3 new messages\nFrom: alice"
        )
    }

    func testMultiMessageBodyCapsAtThreeSendersAndAddsOthers() {
        XCTAssertEqual(
            NotificationContentBuilder.formatBody(for: batch(["A", "B", "C", "D"])),
            "4 new messages\nFrom: D, C, B and others"
        )
    }

    func testMultiMessageBodyMarksUnknownSendersAsOthers() {
        let senders = Array(repeating: "", count: 15) + Array(repeating: "Alice", count: 5)
        XCTAssertEqual(
            NotificationContentBuilder.formatBody(for: batch(senders)),
            "20 new messages\nFrom: Alice and others"
        )
    }

    func testMultiMessageBodyWithNoKnownSenderHasNoFromLine() {
        XCTAssertEqual(NotificationContentBuilder.formatBody(for: batch(["", "", ""])), "3 new messages")
    }

    func testMultiMessageBodyFormatsDisplayNames() {
        XCTAssertEqual(
            NotificationContentBuilder.formatBody(for: batch(["Bob <bob@x.com>", "Ann <ann@x.com>"])),
            "2 new messages\nFrom: Ann, Bob"
        )
    }

    func testThreadIdentifierSetOnMailAndUnreadContent() {
        let account = Account(email: "x@gmail.com", provider: .gmail, alias: "Work")
        let expected = "ding.account.\(account.id.uuidString)"
        XCTAssertEqual(NotificationContentBuilder.threadIdentifier(forAccountID: account.id), expected)

        let mail = NotificationContentBuilder.buildContent(
            for: NewMailEvent(accountID: account.id, messages: batch(["A", "B"])), account: account
        )
        XCTAssertEqual(mail.threadIdentifier, expected)
        XCTAssertEqual(NotificationContentBuilder.buildAccountUnreadContent(account: account, unreadCount: 3).threadIdentifier, expected)
    }

    func testConnectionProblemContentIsTaggedAndNotStacked() {
        let account = Account(email: "x@gmail.com", provider: .gmail, alias: "Work")
        let content = NotificationContentBuilder.buildConnectionProblemContent(account: account)

        XCTAssertEqual(content.title, "Work")
        XCTAssertEqual(content.userInfo[NotificationUserInfoKey.accountID] as? String, account.id.uuidString)
        XCTAssertEqual(content.userInfo[NotificationUserInfoKey.kind] as? String, NotificationUserInfoKey.connectionProblemKind)
        XCTAssertNotEqual(NotificationUserInfoKey.connectionProblemKind, NotificationUserInfoKey.reauthenticationKind)
        XCTAssertEqual(content.threadIdentifier, "", "An outage alert must not fold under a stack of mail")
    }

    func testReauthenticationWordingFollowsCredentialName() {
        let preset = Account(email: "x@gmail.com", provider: .gmail)
        let custom = Account(email: "x@corp.example", provider: .custom, customServer: IMAPServer(host: "mail.corp.example", port: 993))

        XCTAssertTrue(NotificationContentBuilder.buildReauthenticationContent(account: preset).body.hasSuffix("Click to enter a new app password."))
        XCTAssertTrue(NotificationContentBuilder.buildReauthenticationContent(account: custom).body.hasSuffix("Click to enter a new password."))
    }
}
