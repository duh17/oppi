import Foundation
import Testing
@testable import Oppi

@Suite("AppSupportLinks")
struct AppSupportLinksTests {
    @Test func exposesStablePublicHTTPSPages() {
        let privacy = AppSupportLinks.privacyPolicyURL
        let support = AppSupportLinks.supportURL
        let setup = AppSupportLinks.setupURL

        #expect(privacy.scheme == "https")
        #expect(privacy.host == "github.com")
        #expect(privacy.path == "/duh17/oppi/blob/main/docs/privacy.md")

        #expect(support.scheme == "https")
        #expect(support.host == "github.com")
        #expect(support.path == "/duh17/oppi/blob/main/docs/support.md")

        #expect(setup.scheme == "https")
        #expect(setup.host == "github.com")
        #expect(setup.path == "/duh17/oppi/blob/main/docs/onboarding.md")
    }

    @Test func bothPagesAreRepositoryBackedAndDistinct() {
        let privacy = AppSupportLinks.privacyPolicyURL
        let support = AppSupportLinks.supportURL
        let setup = AppSupportLinks.setupURL

        #expect(privacy != support)
        #expect(privacy != setup)
        #expect(support != setup)
        #expect(privacy.path.hasPrefix("/duh17/oppi/blob/main/docs/"))
        #expect(support.path.hasPrefix("/duh17/oppi/blob/main/docs/"))
        #expect(setup.path.hasPrefix("/duh17/oppi/blob/main/docs/"))
    }

    @Test func bothPagesRouteToTheAppWebLinkHandler() async {
        for url in [
            AppSupportLinks.privacyPolicyURL,
            AppSupportLinks.supportURL,
            AppSupportLinks.setupURL,
        ] {
            await confirmation("web link notification for \(url.lastPathComponent)") { confirm in
                let observer = NotificationCenter.default.addObserver(
                    forName: .webLinkTapped,
                    object: nil,
                    queue: nil
                ) { notification in
                    #expect(notification.object as? URL == url)
                    confirm()
                }
                defer { NotificationCenter.default.removeObserver(observer) }

                AppSupportLinks.open(url)
            }
        }
    }
}

