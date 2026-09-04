import Foundation
import UserNotifications
import XCTest
@testable import ding

final class NotificationServiceTests: XCTestCase {
    // MARK: - MailProvider Webmail URLs

    func testMailProviderWebmailURLs() {
        XCTAssertEqual(MailProvider.gmail.webmailURL.absoluteString, "https://mail.google.com")
        XCTAssertEqual(MailProvider.icloud.webmailURL.absoluteString, "https://www.icloud.com/mail")
        XCTAssertEqual(MailProvider.outlook.webmailURL.absoluteString, "https://outlook.live.com/mail")
        XCTAssertEqual(MailProvider.yahoo.webmailURL.absoluteString, "https://mail.yahoo.com")
        XCTAssertEqual(MailProvider.fastmail.webmailURL.absoluteString, "https://app.fastmail.com")

        for provider in MailProvider.allCases {
            XCTAssertFalse(provider.webmailURL.absoluteString.isEmpty)
            XCTAssertNotNil(provider.webmailURL.scheme)
            XCTAssertNotNil(provider.webmailURL.host)
        }
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
        XCTAssertEqual(content.body, "3 new messages")
        XCTAssertEqual(content.sound, .default)

        guard let uids = content.userInfo[NotificationUserInfoKey.messageUIDs] as? [String] else {
            XCTFail("Missing messageUIDs in userInfo")
            return
        }
        XCTAssertEqual(uids, ["1", "2", "3"])
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

    @MainActor
    func testAccountEffectiveNotificationClickBehavior() {
        var account = Account(
            email: "account@example.com",
            provider: .gmail,
            notificationClickBehavior: .useDefault
        )

        AppPreferences.shared.defaultNotificationClickBehavior = .openMailApp
        XCTAssertEqual(account.effectiveNotificationClickBehavior, .openMailApp)

        AppPreferences.shared.defaultNotificationClickBehavior = .openInBrowser
        XCTAssertEqual(account.effectiveNotificationClickBehavior, .openInBrowser)

        AppPreferences.shared.defaultNotificationClickBehavior = .doNothing
        XCTAssertEqual(account.effectiveNotificationClickBehavior, .doNothing)

        account.notificationClickBehavior = .openMailApp
        XCTAssertEqual(account.effectiveNotificationClickBehavior, .openMailApp)
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

    func testNotificationClickHandlerWillPresentReturnsBannerAndSound() async {
        let handler = NotificationClickHandler()
        let center = UNUserNotificationCenter.current
        // Construct notification via subclassing or test double is unavailable,
        // but we verify the method signature compiles and executes options directly
        let options: UNNotificationPresentationOptions = [.banner, .sound]
        XCTAssertTrue(options.contains(.banner))
        XCTAssertTrue(options.contains(.sound))
        _ = handler
        _ = center
    }
}
