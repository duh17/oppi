import Testing
import UIKit
import WebKit
@testable import Oppi

@Suite("HTML DOM element annotation")
@MainActor
struct HTMLDOMElementAnnotationTests {
    @Test func lookupScriptIsReadOnlyAndDoesNotReadRawMarkupOrFormValues() {
        let script = HTMLDOMWebKitLookupClient.lookupFunction
        #expect(HTMLDOMWebKitLookupClient.contentWorldName == "oppi.html-dom-annotation")
        #expect(!script.contains("outerHTML"))
        #expect(!script.contains("innerHTML"))
        #expect(!script.contains("innerText"))
        #expect(!script.contains("textContent"))
        #expect(!script.contains(".value"))
        #expect(!script.contains("click("))
        #expect(!script.contains(".focus("))
        #expect(!script.contains("dispatchEvent"))
        #expect(!script.contains("attachShadow"))
        #expect(!script.contains("eval("))
        #expect(script.contains("globalThis.TextEncoder"))
        #expect(script.contains("0x6a09e667"))
        #expect(script.contains("0xc67178f2"))
        #expect(!script.contains("2166136261"))
        #expect(!script.contains("Math.imul"))
    }

    @Test func viewportMappingDoesNotDoubleApplyPageZoomOrScrollOffset() {
        let zoomed = HTMLDOMViewportMetrics(
            pageZoom: 2,
            scrollZoomScale: 0.5,
            visualViewportScale: 0.5,
            visualViewportOffset: .zero,
            viewportOriginInView: CGPoint(x: 12, y: 62),
            contentOffset: CGPoint(x: 0, y: 80)
        )
        #expect(HTMLDOMViewportMapping.cssViewportPoint(fromViewPoint: CGPoint(x: 200, y: 100), metrics: zoomed) == CGPoint(x: 188, y: 38))
        let rect = HTMLDOMViewportMapping.viewRect(
            fromCSSViewportRect: CGRect(x: 40, y: 20, width: 10, height: 8),
            metrics: zoomed
        )
        #expect(rect == CGRect(x: 52, y: 82, width: 10, height: 8))
    }

    @Test func readerPageZoomDoesNotApplyVisualScrollOffsetTwice() {
        #expect(FullScreenReaderPreferences(textScale: 2).textScale == 1.35)
        let readerZoom = HTMLDOMViewportMetrics(
            pageZoom: 1.25,
            scrollZoomScale: 1,
            visualViewportScale: 1,
            visualViewportOffset: CGPoint(x: 0, y: 89.3375),
            viewportOriginInView: CGPoint(x: 0, y: 62),
            contentOffset: CGPoint(x: 0, y: 140)
        )
        let rect = HTMLDOMViewportMapping.viewRect(
            fromCSSViewportRect: CGRect(x: 74, y: 362.8, width: 150, height: 62),
            metrics: readerZoom
        )
        #expect(abs(rect.minX - 92.5) < 0.01)
        #expect(abs(rect.minY - 515.5) < 0.01)
        #expect(abs(rect.width - 187.5) < 0.01)
        #expect(abs(rect.height - 77.5) < 0.01)
    }

    @Test func viewportMappingUsesVisualPinchWithoutDoubleCountingScrollZoom() {
        let pinched = HTMLDOMViewportMetrics(
            pageZoom: 1.25,
            scrollZoomScale: 0.8,
            visualViewportScale: 1.6,
            visualViewportOffset: CGPoint(x: 10, y: 20),
            viewportOriginInView: .zero,
            contentOffset: CGPoint(x: 40, y: 50)
        )
        let css = HTMLDOMViewportMapping.cssViewportPoint(fromViewPoint: CGPoint(x: 20, y: 40), metrics: pinched)
        #expect(abs(css.x - 10) < 0.001)
        #expect(abs(css.y - 20) < 0.001)
        let roundTrip = HTMLDOMViewportMapping.viewRect(
            fromCSSViewportRect: CGRect(origin: css, size: CGSize(width: 4, height: 6)),
            metrics: pinched
        )
        #expect(abs(roundTrip.origin.x - 20) < 0.001)
        #expect(abs(roundTrip.origin.y - 40) < 0.001)

        let scrollPinch = HTMLDOMViewportMetrics(
            pageZoom: 1,
            scrollZoomScale: 2,
            visualViewportScale: 2,
            visualViewportOffset: .zero,
            viewportOriginInView: .zero,
            contentOffset: CGPoint(x: 30, y: 40)
        )
        let scrollCSS = HTMLDOMViewportMapping.cssViewportPoint(fromViewPoint: CGPoint(x: 10, y: 12), metrics: scrollPinch)
        #expect(scrollCSS == CGPoint(x: 5, y: 6))
    }

    @Test func sanitizerDropsTokenURLsEventHandlersFormValuesAndOversizedPayloads() {
        let cleaned = HTMLDOMSanitizer.sanitizedURL("https://example.com/callback?token=abc123&x=1#frag")
        #expect(cleaned == "https://example.com/callback")
        #expect(HTMLDOMSanitizer.sanitizedURL("javascript:alert(1)") == nil)
        #expect(HTMLDOMSanitizer.sanitizedURL("https://user:secret@example.com/path") == nil)

        let rejected = HTMLDOMSanitizer.sanitize([
            "tagName": "div",
            "outerHTML": "<div>secret</div>",
            "visibleText": "Visible",
            "locator": [["tag": "html", "siblingIndex": 0, "entersOpenShadow": false]],
            "bounds": ["x": 0, "y": 0, "width": 10, "height": 10],
            "isConnected": true,
        ])
        #expect(rejected == .failure(.invalidPayload))

        let valued = HTMLDOMSanitizer.sanitize([
            "tagName": "input",
            "value": "p@ssw0rd",
            "visibleText": "",
            "locator": [["tag": "html", "siblingIndex": 0, "entersOpenShadow": false]],
            "bounds": ["x": 0, "y": 0, "width": 10, "height": 10],
            "isConnected": true,
        ])
        #expect(valued == .failure(.invalidPayload))

        let tooBig = HTMLDOMSanitizer.sanitize([
            "tagName": "p",
            "visibleText": String(repeating: "a", count: HTMLDOMSanitizer.maxTextLength + 1),
            "locator": [["tag": "html", "siblingIndex": 0, "entersOpenShadow": false]],
            "bounds": ["x": 0, "y": 0, "width": 10, "height": 10],
            "isConnected": true,
        ])
        #expect(tooBig == .failure(.payloadTooLarge))

        let eventy = HTMLDOMSanitizer.sanitize(elementPayload(text: "Save", extraAttributes: ["onclick": "steal()"]))
        #expect(eventy == .failure(.invalidPayload))
    }

    @Test func loadedSourceHashMatchDoesNotAcceptAChangedElement() {
        let original = sanitizedElement(text: "Save")
        let snapshot = HTMLDOMSelectionSnapshot(
            generation: 3,
            sessionId: "session-a",
            sourceSHA256: "abc",
            element: original
        )
        let changed = sanitizedElement(text: "Changed")
        let result = HTMLDOMSelectionFreshness.revalidated(
            snapshot: snapshot,
            live: changed,
            currentGeneration: 3,
            currentSessionId: "session-a",
            currentSourceSHA256: "abc",
            filePath: "page.html"
        )
        #expect(result == .failure(.fingerprintMismatch))

        let staleGeneration = HTMLDOMSelectionFreshness.revalidated(
            snapshot: snapshot,
            live: original,
            currentGeneration: 4,
            currentSessionId: "session-a",
            currentSourceSHA256: "abc",
            filePath: "page.html"
        )
        #expect(staleGeneration == .failure(.staleGeneration))

        let otherSession = HTMLDOMSelectionFreshness.revalidated(
            snapshot: snapshot,
            live: original,
            currentGeneration: 3,
            currentSessionId: "session-b",
            currentSourceSHA256: "abc",
            filePath: "page.html"
        )
        #expect(otherSession == .failure(.sessionMismatch))
    }

    @Test func storedDOMCommentOmitsSourceLinesAndSurvivesLegacyDecoding() throws {
        let defaults = try makeDefaults()
        let store = ReviewCommentStore(defaults: defaults, keyPrefix: "html-dom-tests")
        let controller = ChatReviewCommentsController(store: store)
        let anchor = HTMLDOMElementAnchor(
            sourceSHA256: "abc123",
            navigationGeneration: 2,
            sessionId: "session-a",
            filePath: "page.html",
            readableLabel: "button \"Save\"",
            sanitizedText: "Save",
            locatorDescription: "html:0 > body:0 > button:0",
            fingerprint: "finger",
            limitation: "embeddedFrame",
            lookupScope: HTMLDOMElementAnchor.mainFrameAndOpenShadowScope
        )
        let request = ReviewCommentSelectionRequest(
            selectedText: "button \"Save\"",
            source: ReviewCommentSourceContext(
                sessionId: "session-a",
                surface: .fullScreenSource,
                filePath: "page.html",
                lineRange: 4...9,
                languageHint: "html"
            ),
            htmlDOMAnchor: anchor
        )
        let error = controller.save(body: "Rename this control.", request: request, localScopeId: "workspace", sessionId: "session-a")
        #expect(error == nil)
        let saved = try #require(store.stagedComments.first)
        #expect(saved.reference.startLine == nil)
        #expect(saved.reference.endLine == nil)
        #expect(saved.reference.languageHint == nil)
        #expect(saved.reference.htmlDOMAnchor == anchor)
        #expect(!saved.reference.selectedText!.contains("outerHTML"))

        let block = store.appendReviewBlock(to: "")
        #expect(block.contains("**Rendered element:** button \"Save\""))
        #expect(!block.contains("**Location in page:**"))
        #expect(!block.contains("html:0"))
        #expect(!block.contains("abc123"))
        #expect(!block.contains("finger"))
        #expect(block.contains("**Lookup limitation:** Embedded frame"))
        #expect(!block.contains("page.html:4"))
        #expect(!block.contains("```html"), "DOM summary was fenced as HTML source:\n\(block)")
        #expect(block.contains("```\nbutton \"Save\""))
        #expect(block.contains("> Rename this control."))

        let key = ReviewCommentStore.makeStorageKey(prefix: "html-dom-tests", workspaceId: "workspace", sessionId: "session-a")
        let data = try #require(defaults.data(forKey: key))
        var comments = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        var reference = try #require(comments[0]["reference"] as? [String: Any])
        reference.removeValue(forKey: "htmlDOMAnchor")
        comments[0]["reference"] = reference
        defaults.set(try JSONSerialization.data(withJSONObject: comments), forKey: key)

        let reloaded = ReviewCommentStore(defaults: defaults, keyPrefix: "html-dom-tests")
        reloaded.load(workspaceId: "workspace", sessionId: "session-a")
        #expect(reloaded.stagedComments.first?.body == "Rename this control.")
        #expect(reloaded.stagedComments.first?.reference.htmlDOMAnchor == nil)
        #expect(reloaded.stagedComments.first?.reference.selectedText == "button \"Save\"")

        reference["htmlDOMAnchor"] = "not-an-object"
        comments[0]["reference"] = reference
        defaults.set(try JSONSerialization.data(withJSONObject: comments), forKey: key)
        let malformed = ReviewCommentStore(defaults: defaults, keyPrefix: "html-dom-tests")
        malformed.load(workspaceId: "workspace", sessionId: "session-a")
        #expect(malformed.stagedComments.first?.body == "Rename this control.")
        #expect(malformed.stagedComments.first?.reference.htmlDOMAnchor == nil)
    }

    @Test func identicalButtonsInSeparateGroupsHaveReadableDistinctOutgoingContext() async throws {
        let harness = try makeStashHarness()
        let fixture = try await makeFixture(html: """
            <style>body{margin:0}.group,button{display:block;width:120px;height:50px;padding:0}.group button[hidden]{display:none}</style>
            <div id="first" class="group"><button hidden>Hidden</button><button>Save</button></div>
            <div id="second" class="group"><button>Save</button></div>
            """, router: harness.router)
        defer { fixture.window.isHidden = true }
        // An assigned light-DOM button has a rect, but its shadow slot is
        // suppressed; it must not shift the two readable button positions.
        _ = try await pageString("""
            const host = document.createElement('div');
            host.id = 'slot-host';
            document.body.prepend(host);
            host.attachShadow({mode:'open'}).innerHTML = '<slot name="hidden" aria-hidden="true"></slot>';
            const slotted = document.createElement('button');
            slotted.slot = 'hidden';
            slotted.textContent = 'Ignored';
            host.append(slotted);
            'ok'
            """, in: fixture.view)
        let picker = fixture.view.htmlDOMPickControllerForTesting
        picker.enterPick()
        let firstRect = try await cssRect(id: "first", in: fixture.view)
        let firstPoint = try await viewPoint(for: firstRect, in: fixture.view)
        let firstSelection = await pickAndWait(picker, at: firstPoint)
        let first = try #require(firstSelection)
        let firstAnchor = try #require(picker.snapshotForTesting?.anchor())
        let secondRect = try await cssRect(id: "second", in: fixture.view)
        let secondPoint = try await viewPoint(for: secondRect, in: fixture.view)
        let secondSelection = await pickAndWait(picker, at: secondPoint)
        let second = try #require(secondSelection)
        let secondAnchor = try #require(picker.snapshotForTesting?.anchor())
        #expect(first.tagOrdinal == 1, "first=\(first.readableLabel) text=\(first.visibleText)")
        #expect(second.tagOrdinal == 2)
        let firstProse = firstAnchor.promptLines().joined(separator: "\n")
        let secondProse = secondAnchor.promptLines().joined(separator: "\n")
        #expect(firstProse.contains("button \"Save\" (1st button on page)"))
        #expect(secondProse.contains("button \"Save\" (2nd button on page)"))
        #expect(firstProse != secondProse)
        #expect(!firstProse.contains(firstAnchor.locatorDescription))
        #expect(!secondProse.contains(secondAnchor.locatorDescription))
        #expect(!secondProse.contains(secondAnchor.sourceSHA256))
        #expect(!secondProse.contains(secondAnchor.fingerprint))
        #expect(!secondProse.contains("**In its parent:** child"))

        // A different group may gain a control after selection. Its readable
        // page order changes, but the selected node and private locator do not.
        _ = try await pageString(
            "const extra=document.createElement('button'); extra.textContent='Other'; document.getElementById('first').prepend(extra); 'ok'",
            in: fixture.view
        )
        let raw = try await picker.lookupClientForTesting.lookup(
            mode: "revalidate", cssPoint: .zero, locator: second.locator
        )
        let live = try HTMLDOMSanitizer.sanitize(raw).get()
        #expect(live.tagOrdinal == 3)
        #expect(live.fingerprint == second.fingerprint)
        let selectedSnapshot = try #require(picker.snapshotForTesting)
        let currentAnchor = try HTMLDOMSelectionFreshness.revalidated(
            snapshot: selectedSnapshot, live: live,
            currentGeneration: picker.navigationGeneration,
            currentSessionId: selectedSnapshot.sessionId,
            currentSourceSHA256: picker.loadedSourceSHA256,
            filePath: "page.html"
        ).get()
        #expect(currentAnchor.readableLabel.contains("3rd button on page"))
        picker.comment()
        let composer = await waitForView("review-comment.inline-composer", in: fixture.host.view)
        #expect(composer != nil)
        #expect(picker.lastRejection == nil)
    }

    @Test func unavailableStandalonePickerStaysHiddenOnBrowseAndContextRemoval() async throws {
        let fixture = try await makeFixture(html: Self.nestedFixture)
        defer { fixture.window.isHidden = true }
        let picker = fixture.view.htmlDOMPickControllerForTesting
        #expect(picker.canPick)
        #expect(picker.enterButtonForTesting.superview?.superview?.isHidden == false)
        picker.enterPick()
        picker.configure(router: nil, sourceContext: nil)
        #expect(!picker.canPick)
        #expect(!picker.isPicking)
        #expect(picker.enterButtonForTesting.superview?.superview?.isHidden == true)
        picker.exitPick()
        #expect(picker.enterButtonForTesting.superview?.superview?.isHidden == true)
    }

    @Test func pickShieldOwnsTouchesAndDoesNotActivatePageControls() async throws {
        let fixture = try await makeFixture(html: Self.controlFixture)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()

        let trap = try await cssRect(id: "trap", in: fixture.view)
        let point = try await viewPoint(for: trap, in: fixture.view)
        fixture.view.layoutIfNeeded()
        let hit = fixture.view.hitTest(point, with: nil)
        let pagePoint = CGPoint(x: 48, y: min(fixture.view.bounds.height - 48, max(point.y, 240)))
        let pageHit = fixture.view.hitTest(pagePoint, with: nil)
        #expect(pageHit is HTMLDOMPickShieldView, "page hit \(String(describing: pageHit)) point \(pagePoint)")
        #expect(!(hit is WKWebView), "control hit \(String(describing: hit)) point \(point)")
        #expect(hit is HTMLDOMPickShieldView || !(hit is WKWebView))
        #expect(fixture.view.webViewForTesting.isUserInteractionEnabled == false)
        #expect(fixture.view.webViewForTesting.configuration.userContentController.userScripts.isEmpty)
        #expect(controller.bannerTextForTesting == "Pick mode pauses scrolling. Browse to scroll.")

        controller.pick(at: point)
        let selected = try #require(await waitForElement(id: "trap", controller: controller))
        #expect(selected.tag == "button", "selected \(selected.tag)#\(selected.elementId ?? "") bounds \(selected.cssBounds) point \(point)")
        #expect(selected.elementId == "trap")
        #expect(!selected.readableLabel.contains("#trap"), "The private DOM ID must not become comment prose")
        #expect(!selected.summaryText.contains("#trap"))
        let events = try await pageString("JSON.stringify(window.__events || [])", in: fixture.view)
        let active = try await pageString("document.activeElement && document.activeElement.id", in: fixture.view)
        #expect(events == "[]")
        #expect(active != "trap")
        #expect(controller.highlightViewForTesting.isHidden == false)
    }

    @Test func nestedParentSelectionRestoresBrowseWithoutReloading() async throws {
        let fixture = try await makeFixture(html: Self.nestedFixture)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        let generation = fixture.view.navigationGenerationForTesting
        let hash = fixture.view.loadedSourceSHA256ForTesting
        let offset = fixture.view.webViewForTesting.scrollView.contentOffset
        controller.enterPick()

        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        controller.pick(at: try await viewPoint(for: leaf, in: fixture.view))
        let selectedLeaf = try #require(await waitForElement(id: "leaf", controller: controller))
        #expect(selectedLeaf.tag == "button", "selected \(selectedLeaf.tag)#\(selectedLeaf.elementId ?? "") bounds \(selectedLeaf.cssBounds)")

        controller.parentButtonForTesting.sendActions(for: .touchUpInside)
        let inner = try #require(await waitForElement(id: "inner", controller: controller))
        #expect(inner.tag == "div")
        controller.parentButtonForTesting.sendActions(for: .touchUpInside)
        let outer = try #require(await waitForElement(id: "outer", controller: controller))
        #expect(outer.tag == "div")

        controller.exitButtonForTesting.sendActions(for: .touchUpInside)
        #expect(controller.isPicking == false)
        #expect(fixture.view.webViewForTesting.isUserInteractionEnabled == true)
        #expect(controller.bannerTextForTesting == nil || controller.exitButtonForTesting.isHidden)
        let browseHit = fixture.view.hitTest(try await viewPoint(for: leaf, in: fixture.view), with: nil)
        #expect(!(browseHit is HTMLDOMPickShieldView))
        #expect(fixture.view.navigationGenerationForTesting == generation)
        #expect(fixture.view.loadedSourceSHA256ForTesting == hash)
        #expect(fixture.view.webViewForTesting.scrollView.contentOffset == offset)
        #expect(fixture.view.webViewForTesting.configuration.websiteDataStore !== WKWebsiteDataStore.default())
    }

    @Test func selectionTracksScrollAndPageZoom() async throws {
        let fixture = try await makeFixture(html: Self.coordinateFixture)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()

        try await assertPickHitsMarker(in: fixture, controller: controller)

        let beforeScroll = try await cssRect(id: "marker", in: fixture.view)
        fixture.view.webViewForTesting.scrollView.setContentOffset(CGPoint(x: 0, y: 36), animated: false)
        try await Task.sleep(for: .milliseconds(80))
        let scrolled = try await cssRect(id: "marker", in: fixture.view)
        #expect(scrolled.origin.y < beforeScroll.origin.y - 4, "scroll did not move the marker. before \(beforeScroll) after \(scrolled)")
        try await assertPickHitsMarker(in: fixture, controller: controller)

        try await resetViewport(fixture.view.webViewForTesting)
        fixture.view.webViewForTesting.pageZoom = 2
        try await Task.sleep(for: .milliseconds(120))
        let zoomedCSS = try await cssRect(id: "marker", in: fixture.view)
        let zoomedView = try await viewPoint(for: zoomedCSS, in: fixture.view)
        #expect(fixture.view.webViewForTesting.pageZoom == 2)
        #expect(zoomedView.x.isFinite && zoomedView.y.isFinite)
        try await assertPickHitsMarker(in: fixture, controller: controller)

        try await resetViewport(fixture.view.webViewForTesting)
        let webView = fixture.view.webViewForTesting
        webView.scrollView.minimumZoomScale = 0.5
        webView.scrollView.maximumZoomScale = 3
        webView.scrollView.setZoomScale(2, animated: false)
        try await Task.sleep(for: .milliseconds(120))
        webView.scrollView.setContentOffset(.zero, animated: false)
        _ = try await pageString(
            "window.scrollTo(0, 0); document.getElementById('marker').scrollIntoView({block:'center', inline:'center'}); 'ok'",
            in: fixture.view
        )
        try await Task.sleep(for: .milliseconds(80))
        webView.scrollView.setContentOffset(.zero, animated: false)
        try await Task.sleep(for: .milliseconds(80))
        let zoomScale = webView.scrollView.zoomScale
        let visualScale = try await pageNumber("window.visualViewport ? window.visualViewport.scale : 1", in: fixture.view)
        #expect(abs(zoomScale - 1) > 0.05 || abs(visualScale - 1) > 0.05, "WKWebView did not enter a non-1 pinch scale. zoomScale=\(zoomScale) visualScale=\(visualScale)")
        try await assertPickHitsMarker(in: fixture, controller: controller)
    }

    @Test func sanitizerExcludesSensitiveDescendantsShadowsAndFrames() async throws {
        let fixture = try await makeFixture(html: Self.sensitiveFixture)
        defer { fixture.window.isHidden = true }
        try await pageString(
            """
            const host = document.getElementById('open-host');
            const root = host.attachShadow({mode:'open'});
            root.innerHTML = '<button id="open-inner" style="width:100%;height:100%">Open Inner</button><span hidden>OPEN_SHADOW_SECRET</span>';
            class ClosedBox extends HTMLElement { constructor() { super(); const shadow = this.attachShadow({mode:'closed'}); shadow.innerHTML = '<span>SECRET_TOKEN_CLOSED</span>'; } }
            if (!customElements.get('closed-box')) customElements.define('closed-box', ClosedBox);
            const closed = document.createElement('closed-box');
            closed.id = 'closed-host';
            closed.style.cssText = 'position:absolute;left:20px;top:520px;width:150px;height:44px;display:block;background:orange';
            document.body.appendChild(closed);
            'ok';
            """,
            in: fixture.view
        )
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()

        let card = try await cssRect(id: "card", in: fixture.view)
        let cardPoint = CGRect(x: card.midX, y: card.minY + 12, width: 1, height: 1)
        let cardElement = try #require(await pickAndWait(controller, at: try await viewPoint(for: cardPoint, in: fixture.view)))
        let cardText = cardElement.visibleText + cardElement.readableLabel + (cardElement.safeURL ?? "")
        #expect(cardText.contains("Visible card"), "card \(cardElement.tag)#\(cardElement.elementId ?? "") text \(cardText)")
        for secret in ["HIDDEN_SECRET", "DISPLAY_NONE_SECRET", "ARIA_HIDDEN_SECRET", "CLIP_SECRET", "FONT_ZERO_SECRET", "OPACITY_SECRET", "p@ssw0rd", "pw-aria-secret", "pw-title-secret", "user-typed-secret", "editable secret", "editable block secret", "token=abc123", "onclick", "steal("] {
            #expect(!cardText.contains(secret), "leaked \(secret)")
        }
        #expect(cardElement.safeURL == "https://example.com/callback" || cardElement.safeURL == nil)

        let password = try await cssRect(id: "password", in: fixture.view)
        let passwordElement = try #require(await pickAndWait(controller, at: try await viewPoint(for: password, in: fixture.view)))
        #expect(passwordElement.tag == "input", "selected \(passwordElement.tag)#\(passwordElement.elementId ?? "")")
        #expect(passwordElement.inputType == "password")
        let passwordText = passwordElement.visibleText + passwordElement.readableLabel + (passwordElement.accessibleName ?? "")
        #expect(!passwordText.contains("p@ssw0rd"))
        #expect(!passwordText.contains("pw-aria-secret"))
        #expect(!passwordText.contains("pw-title-secret"))

        let titled = try await cssRect(id: "title-secret", in: fixture.view)
        let titledElement = try #require(await pickAndWait(controller, at: try await viewPoint(for: titled, in: fixture.view)))
        let titledText = titledElement.visibleText + titledElement.readableLabel + (titledElement.accessibleName ?? "")
        #expect(titledElement.elementId == nil)
        #expect(titledElement.classes.isEmpty)
        #expect(titledElement.role == nil)
        #expect(!titledText.contains("title-secret"))
        #expect(!titledText.contains("pw-title-secret"))

        let open = try await cssRect(id: "open-host", in: fixture.view)
        let openElement = try #require(await pickAndWait(controller, at: try await viewPoint(for: open, in: fixture.view)))
        #expect(openElement.elementId == "open-inner", "selected \(openElement.tag)#\(openElement.elementId ?? "") limitation \(String(describing: openElement.limitation))")
        #expect(openElement.visibleText.contains("Open Inner"))
        #expect(!openElement.visibleText.contains("OPEN_SHADOW_SECRET"))
        #expect(openElement.limitation == nil)

        let closed = try await cssRect(id: "closed-host", in: fixture.view)
        let closedElement = try #require(await pickAndWait(controller, at: try await viewPoint(for: closed, in: fixture.view)))
        #expect(closedElement.elementId == "closed-host", "selected \(closedElement.tag)#\(closedElement.elementId ?? "")")
        #expect(closedElement.limitation == .closedShadowHost)
        #expect(!closedElement.visibleText.contains("SECRET_TOKEN_CLOSED"))
        #expect(!closedElement.readableLabel.contains("SECRET_TOKEN_CLOSED"))

        let frame = try await cssRect(id: "frame", in: fixture.view)
        let frameElement = try #require(await pickAndWait(controller, at: try await viewPoint(for: frame, in: fixture.view)))
        #expect(frameElement.elementId == "frame", "selected \(frameElement.tag)#\(frameElement.elementId ?? "")")
        #expect(frameElement.limitation == .embeddedFrame)
        #expect(!frameElement.visibleText.contains("IFRAME_SECRET"))
    }

    @Test func composedTreeTextExcludesUndistributedLightDOMAndInactiveSlotFallback() async throws {
        let harness = try makeStashHarness()
        let fixture = try await makeFixture(html: Self.composedTreeFixture, router: harness.router)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()

        let unassigned = try await cssRect(id: "unassigned-host", in: fixture.view)
        let unassignedPoint = CGRect(x: unassigned.maxX - 8, y: unassigned.maxY - 8, width: 1, height: 1)
        let unassignedElement = try #require(await pickAndWait(controller, at: try await viewPoint(for: unassignedPoint, in: fixture.view)))
        #expect(unassignedElement.elementId == "unassigned-host")
        #expect(unassignedElement.visibleText.contains("Rendered button"))
        #expect(!unassignedElement.visibleText.contains("UNDISTRIBUTED_SECRET"))

        let assigned = try await cssRect(id: "assigned-host", in: fixture.view)
        let assignedPoint = CGRect(x: assigned.maxX - 8, y: assigned.maxY - 8, width: 1, height: 1)
        let assignedElement = try #require(await pickAndWait(controller, at: try await viewPoint(for: assignedPoint, in: fixture.view)))
        #expect(assignedElement.elementId == "assigned-host")
        #expect(assignedElement.visibleText.components(separatedBy: "ASSIGNED_VISIBLE").count == 2)
        #expect(!assignedElement.visibleText.contains("INACTIVE_FALLBACK_SECRET"))
        #expect(!assignedElement.visibleText.contains("UNASSIGNED_SLOT_SECRET"))

        let fallback = try await cssRect(id: "fallback-host", in: fixture.view)
        let fallbackPoint = CGRect(x: fallback.maxX - 8, y: fallback.maxY - 8, width: 1, height: 1)
        let fallbackElement = try #require(await pickAndWait(controller, at: try await viewPoint(for: fallbackPoint, in: fixture.view)))
        #expect(fallbackElement.elementId == "fallback-host")
        #expect(fallbackElement.visibleText.contains("ACTIVE_FALLBACK"))

        controller.pick(at: try await viewPoint(for: unassignedPoint, in: fixture.view))
        _ = try #require(await waitForElement(id: "unassigned-host", controller: controller))
        let request = try #require(controller.preparedRequestForTesting())
        #expect(harness.controller.save(
            body: "Review the rendered host.",
            request: request,
            localScopeId: "workspace",
            sessionId: "session-html"
        ) == nil)
        let saved = try #require(harness.store.stagedComments.last)
        let outgoing = harness.store.appendReviewBlock(to: "")
        #expect(!(saved.reference.selectedText ?? "").contains("UNDISTRIBUTED_SECRET"))
        let savedAnchorText = saved.reference.htmlDOMAnchor?.sanitizedText ?? ""
        #expect(!savedAnchorText.contains("UNDISTRIBUTED_SECRET"))
        #expect(!outgoing.contains("UNDISTRIBUTED_SECRET"))
    }

    @Test func closedShadowUndistributedLightTextDoesNotLeakIntoSavedPrompt() async throws {
        let harness = try makeStashHarness()
        let fixture = try await makeFixture(html: Self.closedShadowLightDOMFixture, router: harness.router)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let secrets = ["SECRET_CLOSED_CUSTOM", "SECRET_CLOSED_ORDINARY"]

        func blob(for element: HTMLDOMSanitizedElement, savedText: String = "", outgoing: String = "") -> String {
            [
                element.visibleText,
                element.readableLabel,
                element.summaryText,
                element.accessibleName ?? "",
                savedText,
                outgoing,
            ].joined(separator: "\n")
        }

        func assertAbsent(secrets: [String], in text: String, from label: String) {
            for secret in secrets {
                #expect(!text.contains(secret), "leaked \(secret) from \(label):\n\(text)")
            }
        }

        func saveCurrent(body: String) throws -> (savedText: String, outgoing: String) {
            let request = try #require(controller.preparedRequestForTesting())
            #expect(harness.controller.save(
                body: body,
                request: request,
                localScopeId: "workspace",
                sessionId: "session-html"
            ) == nil)
            let saved = try #require(harness.store.stagedComments.last)
            let savedText = (saved.reference.selectedText ?? "") + "\n" + (saved.reference.htmlDOMAnchor?.sanitizedText ?? "")
            return (savedText, harness.store.appendReviewBlock(to: ""))
        }

        let custom = try await cssRect(id: "closed-custom", in: fixture.view)
        let customElement = try #require(await pickAndWait(controller, at: try await viewPoint(for: custom, in: fixture.view)))
        #expect(customElement.elementId == "closed-custom")
        let customSaved = try saveCurrent(body: "Review the closed custom host.")
        assertAbsent(
            secrets: secrets,
            in: blob(for: customElement, savedText: customSaved.savedText, outgoing: customSaved.outgoing),
            from: "closed-custom"
        )

        let ordinary = try await cssRect(id: "closed-ordinary", in: fixture.view)
        let ordinaryElement = try #require(await pickAndWait(controller, at: try await viewPoint(for: ordinary, in: fixture.view)))
        #expect(ordinaryElement.elementId == "closed-ordinary")
        let ordinarySaved = try saveCurrent(body: "Review the closed ordinary host.")
        assertAbsent(
            secrets: secrets,
            in: blob(for: ordinaryElement, savedText: ordinarySaved.savedText, outgoing: ordinarySaved.outgoing),
            from: "closed-ordinary"
        )

        let ancestor = try await cssRect(id: "closed-ancestor", in: fixture.view)
        let ancestorPoint = CGRect(x: ancestor.midX, y: ancestor.minY + 10, width: 1, height: 1)
        let ancestorElement = try #require(await pickAndWait(controller, at: try await viewPoint(for: ancestorPoint, in: fixture.view)))
        #expect(ancestorElement.elementId == "closed-ancestor", "selected \(ancestorElement.tag)#\(ancestorElement.elementId ?? "")")
        #expect(ancestorElement.visibleText.contains("Visible ancestor"))
        let ancestorSaved = try saveCurrent(body: "Review the ancestor of closed hosts.")
        assertAbsent(
            secrets: secrets,
            in: blob(for: ancestorElement, savedText: ancestorSaved.savedText, outgoing: ancestorSaved.outgoing),
            from: "closed-ancestor"
        )
    }

    @Test func isolatedSHA256MatchesCryptoKitAtPaddingUnicodeAndSizeBoundaries() async throws {
        let fixture = try await makeFixture(html: Self.digestFixture)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let target = try await cssRect(id: "digest-target", in: fixture.view)
        controller.pick(at: try await viewPoint(for: target, in: fixture.view))
        let selected = try #require(await waitForElement(id: "digest-target", controller: controller))
        let locator = selected.locator

        let cases: [(label: String, value: String)] = [
            ("empty", ""),
            ("55", String(repeating: "a", count: 55)),
            ("56", String(repeating: "a", count: 56)),
            ("63", String(repeating: "a", count: 63)),
            ("64", String(repeating: "a", count: 64)),
            ("65", String(repeating: "a", count: 65)),
            ("unicode", "你好🙂e\u{301}"),
            ("maximum", String(repeating: "x", count: 1_048_576)),
        ]
        for fixtureCase in cases {
            _ = try await pageString(
                "document.getElementById('digest-target').textContent = value; 'ok'",
                arguments: ["value": fixtureCase.value],
                in: fixture.view
            )
            let raw = try await controller.lookupClientForTesting.lookup(
                mode: "revalidate",
                cssPoint: .zero,
                locator: locator
            )
            let digest = try #require(HTMLDOMSanitizer.string(raw["textDigest"]))
            #expect(
                digest == HTMLDOMSourceIdentity.sha256Hex(fixtureCase.value),
                "SHA mismatch for \(fixtureCase.label)"
            )
        }

        _ = try await pageString(
            "document.getElementById('digest-target').textContent = 'x'.repeat(1048577); 'ok'",
            in: fixture.view
        )
        do {
            _ = try await controller.lookupClientForTesting.lookup(
                mode: "revalidate",
                cssPoint: .zero,
                locator: locator
            )
            Issue.record("Oversize SHA input was accepted")
        } catch {
            #expect(String(describing: error).contains("too large"))
        }
    }

    @Test func viewportRefreshRejectsACloneInsteadOfAdoptingIt() async throws {
        let harness = try makeStashHarness()
        let fixture = try await makeFixture(html: Self.nestedFixture, router: harness.router)
        defer { fixture.window.isHidden = true }
        let kept = try harness.store.create(
            workspaceId: "workspace",
            sessionId: "session-html",
            body: "Keep this draft.",
            reference: ReviewCommentReference(source: .file, path: "page.html", selectedText: "existing")
        )
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        controller.pick(at: try await viewPoint(for: leaf, in: fixture.view))
        let original = try #require(await waitForElement(id: "leaf", controller: controller))
        _ = try await pageString(
            "const node=document.getElementById('leaf'); node.replaceWith(node.cloneNode(true)); 'ok'",
            in: fixture.view
        )

        let serial = controller.completedLookupSerial
        fixture.view.applyReaderPreferences(FullScreenReaderPreferences(textScale: 1.25, wrapsText: true))
        _ = await waitForCompletedLookup(controller, after: serial)
        #expect(controller.lastRejection == .fingerprintMismatch)
        #expect(controller.snapshotForTesting == nil || controller.snapshotForTesting?.fingerprint == original.fingerprint)

        controller.commentButtonForTesting.sendActions(for: .touchUpInside)
        if let composer = await waitForView("review-comment.inline-composer", in: fixture.host.view, attempts: 5),
           let input = find("review-comment.inline-input", in: composer) as? UITextView,
           let save = find("review-comment.inline-save", in: composer) as? UIButton {
            input.text = "A clone must not be adopted."
            input.delegate?.textViewDidChange?(input)
            save.sendActions(for: .touchUpInside)
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(harness.store.stagedComments.map(\.id) == [kept.id])
        #expect(harness.saves.isEmpty)
    }

    @Test func interruptedSaveCannotCrossABrowseAndNewPickSession() async throws {
        let harness = try makeStashHarness()
        let fixture = try await makeFixture(html: Self.nestedFixture, router: harness.router)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        controller.pick(at: try await viewPoint(for: leaf, in: fixture.view))
        _ = try #require(await waitForElement(id: "leaf", controller: controller))
        controller.commentButtonForTesting.sendActions(for: .touchUpInside)
        let composer = try #require(await waitForView("review-comment.inline-composer", in: fixture.host.view))
        let input = try #require(find("review-comment.inline-input", in: composer) as? UITextView)
        input.text = "Keep this draft, but do not save it."
        input.delegate?.textViewDidChange?(input)
        let save = try #require(find("review-comment.inline-save", in: composer) as? UIButton)

        let gate = ResumeGate()
        var saveLookupStarted = false
        controller.lookupClientForTesting.beforeCallForTesting = { mode in
            guard mode == "revalidate", !saveLookupStarted else { return }
            saveLookupStarted = true
            await gate.wait()
        }
        save.sendActions(for: .touchUpInside)
        #expect(await waitUntil { saveLookupStarted })
        controller.exitPick()
        controller.enterPick()
        controller.pick(at: try await viewPoint(for: leaf, in: fixture.view))
        _ = try #require(await waitForElement(id: "leaf", controller: controller))
        let newerStatus = controller.statusTextForTesting
        let newerRejection = controller.lastRejection
        let newerFingerprint = controller.snapshotForTesting?.fingerprint
        gate.resume()

        #expect(await waitUntil { save.isEnabled })
        #expect(harness.store.stagedComments.isEmpty)
        #expect(harness.saves.isEmpty)
        #expect(find("review-comment.inline-composer", in: fixture.host.view) === composer)
        #expect(input.text == "Keep this draft, but do not save it.")
        #expect(controller.statusTextForTesting == newerStatus)
        #expect(controller.lastRejection == newerRejection)
        #expect(controller.snapshotForTesting?.fingerprint == newerFingerprint)
        #expect(controller.statusTextForTesting?.contains("Nothing was saved") != true)
        #expect(controller.statusTextForTesting?.contains("The page reloaded") != true)
        #expect(controller.statusTextForTesting?.contains("Couldn't read that element") != true)
    }

    @Test func pageWorldOverrideDoesNotBecomeANativeAction() async throws {
        let fixture = try await makeFixture(html: Self.controlFixture)
        defer { fixture.window.isHidden = true }
        _ = try await pageString(
            """
            document.elementFromPoint = function() { return document.getElementById('trap'); };
            Element.prototype.getBoundingClientRect = function() { return {x:0,y:0,width:1,height:1,top:0,left:0,right:1,bottom:1}; };
            'ok';
            """,
            in: fixture.view
        )
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let marker = try await contentWorldRect(id: "other", in: fixture.view)
        controller.pick(at: try await viewPoint(for: marker, in: fixture.view))
        let selected = try #require(await waitForSnapshot(controller))
        #expect(selected.elementId == "other")
        #expect(selected.elementId != "trap")
        let url = fixture.view.webViewForTesting.url?.absoluteString ?? ""
        #expect(!url.hasPrefix("javascript:"))
        let events = try await pageString("JSON.stringify(window.__events || [])", in: fixture.view)
        #expect(events == "[]")
    }

    @Test func staleMutationNavigationAndLateCallbackDoNotStageAComment() async throws {
        let harness = try makeStashHarness()
        let fixture = try await makeFixture(html: Self.nestedFixture, router: harness.router)
        defer { fixture.window.isHidden = true }
        let kept = try harness.store.create(
            workspaceId: "workspace",
            sessionId: "session-html",
            body: "Keep this draft.",
            reference: ReviewCommentReference(source: .file, path: "page.html", selectedText: "existing")
        )
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        controller.pick(at: try await viewPoint(for: leaf, in: fixture.view))
        _ = try #require(await waitForElement(id: "leaf", controller: controller))

        _ = try await pageString("document.getElementById('leaf').textContent = 'changed-label'", in: fixture.view)
        controller.commentButtonForTesting.sendActions(for: .touchUpInside)
        #expect(await waitForStatus(containing: "Nothing was saved", controller: controller))
        #expect(find("review-comment.inline-composer", in: fixture.host.view) == nil)
        #expect(harness.saves.isEmpty)
        #expect(harness.dispatches.isEmpty)
        #expect(harness.store.stagedComments.map(\.id) == [kept.id])

        controller.pick(at: try await viewPoint(for: leaf, in: fixture.view))
        _ = try #require(await waitForSnapshot(controller))
        _ = try await pageString("document.getElementById('leaf').remove()", in: fixture.view)
        controller.commentButtonForTesting.sendActions(for: .touchUpInside)
        #expect(await waitForStatus(containing: "Nothing was saved", controller: controller))
        #expect(harness.saves.isEmpty)

        let generation = fixture.view.navigationGenerationForTesting
        fixture.view.webView(fixture.view.webViewForTesting, didStartProvisionalNavigation: nil)
        #expect(fixture.view.navigationGenerationForTesting == generation + 1)
        #expect(controller.snapshotForTesting == nil)

        controller.beforeLookupResumeForTesting = {
            fixture.view.webView(fixture.view.webViewForTesting, didStartProvisionalNavigation: nil)
        }
        controller.pick(at: CGPoint(x: 40, y: 280))
        #expect(await waitUntil { controller.staleLookupCount > 0 })
        #expect(controller.snapshotForTesting == nil)
        #expect(harness.saves.isEmpty)
        #expect(harness.dispatches.isEmpty)
        #expect(harness.store.stagedComments.map(\.body) == ["Keep this draft."])
    }

    @Test func commentSavesSanitizedReferenceThroughTheExistingStashThenBrowseRestores() async throws {
        let harness = try makeStashHarness()
        let fixture = try await makeFixture(html: Self.nestedFixture, router: harness.router)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        controller.pick(at: try await viewPoint(for: leaf, in: fixture.view))
        _ = try #require(await waitForElement(id: "leaf", controller: controller))
        let hash = fixture.view.loadedSourceSHA256ForTesting

        controller.commentButtonForTesting.sendActions(for: .touchUpInside)
        let composer = try #require(await waitForView("review-comment.inline-composer", in: fixture.host.view))
        let input = try #require(find("review-comment.inline-input", in: composer) as? UITextView)
        input.text = "Please rename this leaf."
        input.delegate?.textViewDidChange?(input)
        let save = try #require(find("review-comment.inline-save", in: composer) as? UIButton)
        save.sendActions(for: .touchUpInside)
        #expect(await waitUntil { harness.store.stagedCount == 1 })

        let staged = try #require(harness.store.stagedComments.first)
        #expect(staged.body == "Please rename this leaf.")
        #expect(staged.sessionId == "session-html")
        #expect(staged.reference.path == "page.html")
        #expect(staged.reference.startLine == nil)
        #expect(staged.reference.endLine == nil)
        let anchor = try #require(staged.reference.htmlDOMAnchor)
        #expect(anchor.sourceSHA256 == hash)
        #expect(anchor.sessionId == "session-html")
        #expect(anchor.lookupScope == HTMLDOMElementAnchor.mainFrameAndOpenShadowScope)
        #expect(anchor.locatorDescription.contains("button:"))
        #expect(anchor.readableLabel.contains("leaf") || anchor.sanitizedText.contains("Leaf") || staged.reference.selectedText?.contains("Leaf") == true)
        #expect(!anchor.sanitizedText.contains("outerHTML"))
        let prompt = harness.store.appendReviewBlock(to: "Please review.")
        #expect(prompt.contains("Please review."))
        #expect(prompt.contains("**Rendered element:**"))
        #expect(!prompt.contains(hash))
        #expect(!prompt.contains("**DOM locator:**"))
        #expect(!prompt.contains("**Location in page:**"))
        #expect(!prompt.contains("**Element fingerprint:**"))
        #expect(!prompt.contains("not an original source line"))
        #expect(prompt.contains("> Please rename this leaf."))
        #expect(harness.dispatches.isEmpty)
        #expect(harness.saves.count == 1)

        controller.exitButtonForTesting.sendActions(for: .touchUpInside)
        #expect(controller.isPicking == false)
        #expect(fixture.view.webViewForTesting.isUserInteractionEnabled == true)
        #expect(fixture.view.webViewForTesting.reviewCommentHandler != nil)
        let hit = fixture.view.hitTest(try await viewPoint(for: leaf, in: fixture.view), with: nil)
        #expect(!(hit is HTMLDOMPickShieldView))
    }

    @Test func lateLookupAfterBrowseDoesNotRestoreHighlight() async throws {
        let fixture = try await makeFixture(html: Self.nestedFixture)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        let point = try await viewPoint(for: leaf, in: fixture.view)
        let stale = controller.staleLookupCount
        let gate = ResumeGate()
        var started = false
        controller.lookupClientForTesting.beforeCallForTesting = { mode in
            guard mode == "hit", !started else { return }
            started = true
            await gate.wait()
        }
        controller.pick(at: point)
        let began = await waitUntil { started }
        #expect(began)
        controller.exitPick()
        gate.resume()

        let finished = await waitUntil {
            controller.staleLookupCount > stale || controller.snapshotForTesting != nil
        }
        #expect(finished)
        #expect(controller.snapshotForTesting == nil)
        #expect(controller.highlightViewForTesting.isHidden)
        #expect(controller.isPicking == false)
        #expect(controller.selectionLabelForTesting == nil)
        #expect(fixture.view.webViewForTesting.isUserInteractionEnabled)
        #expect(find("review-comment.inline-composer", in: fixture.host.view) == nil)
    }

    @Test func lateCommentAfterBrowseDoesNotPresentComposerOrError() async throws {
        let harness = try makeStashHarness()
        let fixture = try await makeFixture(html: Self.nestedFixture, router: harness.router)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        controller.pick(at: try await viewPoint(for: leaf, in: fixture.view))
        _ = try #require(await waitForElement(id: "leaf", controller: controller))

        let successStale = controller.staleLookupCount
        let successGate = ResumeGate()
        var successStarted = false
        controller.lookupClientForTesting.beforeCallForTesting = { mode in
            guard mode == "revalidate", !successStarted else { return }
            successStarted = true
            await successGate.wait()
        }
        controller.commentButtonForTesting.sendActions(for: .touchUpInside)
        #expect(await waitUntil { successStarted })
        controller.exitPick()
        successGate.resume()
        let successComposer = await waitForComposerOrStale(controller, stale: successStale, in: fixture.host.view)
        #expect(successComposer == nil)
        #expect(controller.staleLookupCount > successStale)
        #expect(controller.isPicking == false)
        #expect(controller.highlightViewForTesting.isHidden)
        #expect(controller.statusTextForTesting?.contains("Nothing was saved") != true)
        #expect(harness.saves.isEmpty)

        controller.enterPick()
        controller.pick(at: try await viewPoint(for: leaf, in: fixture.view))
        _ = try #require(await waitForElement(id: "leaf", controller: controller))
        let errorStale = controller.staleLookupCount
        let errorGate = ResumeGate()
        var errorStarted = false
        controller.lookupClientForTesting.beforeCallForTesting = { mode in
            guard mode == "revalidate", !errorStarted else { return }
            errorStarted = true
            await errorGate.wait()
        }
        controller.commentButtonForTesting.sendActions(for: .touchUpInside)
        #expect(await waitUntil { errorStarted })
        _ = try await pageString("document.getElementById('leaf').remove()", in: fixture.view)
        controller.exitPick()
        errorGate.resume()
        let errorComposer = await waitForComposerOrStale(controller, stale: errorStale, in: fixture.host.view)
        #expect(errorComposer == nil)
        #expect(controller.staleLookupCount > errorStale)
        #expect(controller.isPicking == false)
        #expect(controller.highlightViewForTesting.isHidden)
        #expect(controller.statusTextForTesting?.contains("Nothing was saved") != true)
        #expect(harness.saves.isEmpty)
        #expect(harness.store.stagedComments.isEmpty)
    }

    @Test func exitThenReenterDropsTheLateLookup() async throws {
        let fixture = try await makeFixture(html: Self.nestedFixture)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        let point = try await viewPoint(for: leaf, in: fixture.view)
        let stale = controller.staleLookupCount
        let gate = ResumeGate()
        var started = false
        controller.lookupClientForTesting.beforeCallForTesting = { mode in
            guard mode == "hit", !started else { return }
            started = true
            await gate.wait()
        }
        controller.pick(at: point)
        #expect(await waitUntil { started })
        controller.exitPick()
        controller.enterPick()
        gate.resume()

        let finished = await waitUntil {
            controller.staleLookupCount > stale || controller.snapshotForTesting != nil
        }
        #expect(finished)
        #expect(controller.isPicking)
        #expect(controller.snapshotForTesting == nil)
        #expect(controller.highlightViewForTesting.isHidden)
        #expect(controller.selectionLabelForTesting == nil)
    }

    @Test func supersededCommentDoesNotClearNewerSelectionOrUseCapturedSession() async throws {
        let harness = try makeStashHarness()
        let fixture = try await makeFixture(html: Self.nestedFixture, router: harness.router)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        let point = try await viewPoint(for: leaf, in: fixture.view)
        controller.pick(at: point)
        _ = try #require(await waitForElement(id: "leaf", controller: controller))

        let stale = controller.staleLookupCount
        controller.beforeLookupResumeForTesting = {
            controller.beforeLookupResumeForTesting = nil
            controller.parentButtonForTesting.sendActions(for: .touchUpInside)
            _ = await self.waitForElement(id: "inner", controller: controller)
            _ = try? await self.pageString(
                "document.getElementById('leaf').textContent = 'changed-after-parent'",
                in: fixture.view
            )
        }
        controller.commentButtonForTesting.sendActions(for: .touchUpInside)
        let composer = await waitForComposerOrStale(controller, stale: stale, in: fixture.host.view)
        #expect(composer == nil)
        #expect(controller.snapshotForTesting?.element.elementId == "inner")
        #expect(controller.highlightViewForTesting.isHidden == false)
        #expect(controller.statusTextForTesting?.contains("Nothing was saved") != true)
        #expect(harness.saves.isEmpty)

        controller.pick(at: point)
        _ = try #require(await waitForElement(id: "leaf", controller: controller))
        controller.beforeLookupResumeForTesting = {
            controller.configure(
                router: harness.router,
                sourceContext: ReviewCommentSourceContext(
                    sessionId: "session-other",
                    surface: .fullScreenSource,
                    filePath: "page.html"
                )
            )
            controller.beforeLookupResumeForTesting = nil
        }
        controller.commentButtonForTesting.sendActions(for: .touchUpInside)
        let sessionComposer = await waitForView("review-comment.inline-composer", in: fixture.host.view, attempts: 20)
        #expect(sessionComposer == nil)
        #expect(harness.saves.isEmpty)
        #expect(harness.dispatches.isEmpty)
        #expect(harness.store.stagedComments.isEmpty)
    }

    @Test func enterPickResignsNativeKeyboardOwnershipWithoutADomWrite() async throws {
        let fixture = try await makeFixture(html: Self.focusFixture)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        let webView = fixture.view.webViewForTesting
        #expect(!HTMLDOMWebKitLookupClient.lookupFunction.contains(".blur("))
        #expect(!HTMLDOMWebKitLookupClient.lookupFunction.contains("activeElement"))
        _ = try await pageString("document.getElementById('name').focus(); 'ok'", in: fixture.view)
        #expect(try await pageString("document.activeElement && document.activeElement.id", in: fixture.view) == "name")
        let nativeInput = UITextField(frame: CGRect(x: 0, y: 0, width: 120, height: 44))
        fixture.host.view.addSubview(nativeInput)
        #expect(nativeInput.becomeFirstResponder())
        #expect(nativeInput.isFirstResponder)
        let before = try await pageString("document.getElementById('name').value", in: fixture.view)

        controller.enterPick()

        #expect(!nativeInput.isFirstResponder)
        let responderAfterPick = currentFirstResponder()
        #expect(responderAfterPick.map { !isDescendantResponder($0, of: webView) } ?? true)
        (responderAfterPick as? UIKeyInput)?.insertText("leak")
        let after = try await pageString("document.getElementById('name').value", in: fixture.view)
        #expect(after == before)
        #expect(!after.contains("leak"))
        #expect(try await pageString("document.activeElement && document.activeElement.id", in: fixture.view) == "name")
        let events = try await pageString("JSON.stringify(window.__events || [])", in: fixture.view)
        #expect(!events.contains("click:"))
    }

    @Test func replacedNodeAndUntruncatedTextChangeAreRejectedBeforeStaging() async throws {
        let harness = try makeStashHarness()
        let fixture = try await makeFixture(html: Self.nestedFixture, router: harness.router)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        let point = try await viewPoint(for: leaf, in: fixture.view)
        let beforeMarkup = try await pageString("document.getElementById('leaf').outerHTML", in: fixture.view)
        controller.pick(at: point)
        _ = try #require(await waitForElement(id: "leaf", controller: controller))
        let afterMarkup = try await pageString("document.getElementById('leaf').outerHTML", in: fixture.view)
        #expect(afterMarkup == beforeMarkup)
        #expect(!HTMLDOMWebKitLookupClient.lookupFunction.contains("setAttribute"))

        _ = try await pageString(
            """
            (() => {
              const node = document.getElementById('leaf');
              const clone = node.cloneNode(true);
              node.replaceWith(clone);
              return 'ok';
            })()
            """,
            in: fixture.view
        )
        controller.commentButtonForTesting.sendActions(for: .touchUpInside)
        #expect(await waitForStatus(containing: "Nothing was saved", controller: controller))
        #expect(find("review-comment.inline-composer", in: fixture.host.view) == nil)
        #expect(harness.saves.isEmpty)
    }

    @Test func textChangePastTheStoredExcerptIsRejected() async throws {
        let harness = try makeStashHarness()
        let fixture = try await makeFixture(html: Self.nestedFixture, router: harness.router)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        let point = try await viewPoint(for: leaf, in: fixture.view)
        _ = try await pageString(
            """
            (() => {
              const prefix = 'A'.repeat(240);
              document.getElementById('leaf').textContent = prefix + 'TAIL_ONE';
              return 'ok';
            })()
            """,
            in: fixture.view
        )
        controller.pick(at: point)
        let longLeaf = try #require(await waitForElement(id: "leaf", controller: controller))
        #expect(longLeaf.visibleText.count <= 240)
        #expect(!longLeaf.visibleText.contains("TAIL_ONE"))
        #expect(longLeaf.textDigest.count == 64)
        #expect(longLeaf.textDigest.allSatisfy { $0.isHexDigit })
        #expect(longLeaf.textDigest == HTMLDOMSourceIdentity.sha256Hex(String(repeating: "A", count: 240) + "TAIL_ONE"))
        _ = try await pageString(
            """
            (() => {
              const prefix = 'A'.repeat(240);
              document.getElementById('leaf').textContent = prefix + 'TAIL_TWO';
              return 'ok';
            })()
            """,
            in: fixture.view
        )
        controller.commentButtonForTesting.sendActions(for: .touchUpInside)
        #expect(await waitForStatus(containing: "Nothing was saved", controller: controller))
        #expect(find("review-comment.inline-composer", in: fixture.host.view) == nil)
        #expect(harness.saves.isEmpty)
        #expect(harness.store.stagedComments.isEmpty)
    }

    @Test func changeAfterComposerOpensIsRejectedWhenSaving() async throws {
        let harness = try makeStashHarness()
        let fixture = try await makeFixture(html: Self.nestedFixture, router: harness.router)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        controller.pick(at: try await viewPoint(for: leaf, in: fixture.view))
        _ = try #require(await waitForElement(id: "leaf", controller: controller))
        controller.commentButtonForTesting.sendActions(for: .touchUpInside)
        let composer = try #require(await waitForView("review-comment.inline-composer", in: fixture.host.view))
        _ = try await pageString("document.getElementById('leaf').textContent = 'changed-before-save'", in: fixture.view)
        let input = try #require(find("review-comment.inline-input", in: composer) as? UITextView)
        input.text = "Please rename this leaf."
        input.delegate?.textViewDidChange?(input)
        let save = try #require(find("review-comment.inline-save", in: composer) as? UIButton)
        save.sendActions(for: .touchUpInside)

        #expect(await waitForStatus(containing: "Nothing was saved", controller: controller))
        try await Task.sleep(for: .milliseconds(250))
        #expect(harness.saves.isEmpty)
        #expect(harness.dispatches.isEmpty)
        #expect(harness.store.stagedComments.isEmpty)
    }

    @Test func browseAfterComposerOpensCannotStageTheSelection() async throws {
        let harness = try makeStashHarness()
        let fixture = try await makeFixture(html: Self.nestedFixture, router: harness.router)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        controller.pick(at: try await viewPoint(for: leaf, in: fixture.view))
        _ = try #require(await waitForElement(id: "leaf", controller: controller))
        controller.commentButtonForTesting.sendActions(for: .touchUpInside)
        let composer = try #require(await waitForView("review-comment.inline-composer", in: fixture.host.view))
        controller.exitPick()

        let input = try #require(find("review-comment.inline-input", in: composer) as? UITextView)
        input.text = "This selection is stale after Browse."
        input.delegate?.textViewDidChange?(input)
        let save = try #require(find("review-comment.inline-save", in: composer) as? UIButton)
        save.sendActions(for: .touchUpInside)

        #expect(await waitUntil { controller.lastRejection == .staleGeneration })
        #expect(harness.saves.isEmpty)
        #expect(harness.dispatches.isEmpty)
        #expect(harness.store.stagedComments.isEmpty)
    }

    @Test func pickControlsUseBrowseWordingAndFortyFourPointTargets() async throws {
        let fixture = try await makeFixture(html: Self.nestedFixture)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        fixture.view.layoutIfNeeded()
        #expect(controller.enterButtonForTesting.bounds.height >= 44)
        controller.enterPick()
        fixture.view.layoutIfNeeded()
        #expect(controller.bannerTextForTesting == "Pick mode pauses scrolling. Browse to scroll.")
        #expect(controller.exitButtonForTesting.bounds.height >= 44)
        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        controller.pick(at: try await viewPoint(for: leaf, in: fixture.view))
        _ = try #require(await waitForElement(id: "leaf", controller: controller))
        fixture.view.layoutIfNeeded()
        #expect(controller.parentButtonForTesting.bounds.height >= 44)
        #expect(controller.commentButtonForTesting.bounds.height >= 44)

        let traitHost = UIViewController()
        fixture.host.addChild(traitHost)
        traitHost.view.frame = CGRect(x: 0, y: 0, width: 20, height: 20)
        fixture.host.view.addSubview(traitHost.view)
        traitHost.didMove(toParent: fixture.host)
        let highlight = HTMLDOMHighlightView(frame: traitHost.view.bounds)
        traitHost.view.addSubview(highlight)

        fixture.host.setOverrideTraitCollection(
            UITraitCollection(userInterfaceStyle: .light),
            forChild: traitHost
        )
        #expect(await waitUntil { highlight.traitCollection.userInterfaceStyle == .light })
        let light = try #require(highlight.layer.borderColor)
        let expectedLight = UIColor.systemBlue.resolvedColor(with: highlight.traitCollection).cgColor
        #expect(light == expectedLight, "border \(light) expected \(expectedLight)")

        fixture.host.setOverrideTraitCollection(
            UITraitCollection(userInterfaceStyle: .dark),
            forChild: traitHost
        )
        #expect(await waitUntil { highlight.traitCollection.userInterfaceStyle == .dark })
        let dark = try #require(highlight.layer.borderColor)
        let expectedDark = UIColor.systemBlue.resolvedColor(with: highlight.traitCollection).cgColor
        #expect(dark == expectedDark, "border \(dark) expected \(expectedDark)")
    }

    @Test func cancellingTheComposerDoesNotStageOrDispatch() async throws {
        let harness = try makeStashHarness()
        let fixture = try await makeFixture(html: Self.nestedFixture, router: harness.router)
        defer { fixture.window.isHidden = true }
        let controller = fixture.view.htmlDOMPickControllerForTesting
        controller.enterPick()
        let leaf = try await cssRect(id: "leaf", in: fixture.view)
        controller.pick(at: try await viewPoint(for: leaf, in: fixture.view))
        _ = try #require(await waitForElement(id: "leaf", controller: controller))
        controller.commentButtonForTesting.sendActions(for: .touchUpInside)
        let composer = try #require(await waitForView("review-comment.inline-composer", in: fixture.host.view))
        let dismiss = try #require(find("review-comment.inline-dismiss", in: composer) as? UIButton)
        dismiss.sendActions(for: .touchUpInside)
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.store.stagedComments.isEmpty)
        #expect(harness.saves.isEmpty)
        #expect(harness.dispatches.isEmpty)
        #expect(find("review-comment.inline-composer", in: fixture.host.view) == nil)
    }

    private static let focusFixture = """
    <!doctype html><html><head></head><body style="margin:0">
    <input id="name" type="text" value="" style="position:absolute;left:24px;top:240px;width:180px;height:44px">
    <button id="other" style="position:absolute;left:24px;top:320px;width:120px;height:44px">Other</button>
    <script>
    window.__events = [];
    document.addEventListener('click', (event) => {
      window.__events.push('click:' + ((event.target && event.target.id) || ''));
    }, true);
    </script>
    </body></html>
    """

    private static let controlFixture = """
    <!doctype html><html><head></head><body style="margin:0">
    <button id="trap" style="position:absolute;left:24px;top:520px;width:140px;height:48px">Go</button>
    <div id="other" style="position:absolute;left:180px;top:260px;width:80px;height:48px;background:#ccc">Other</div>
    <script>
    window.__events = [];
    const record = (event) => window.__events.push(event.type + ':' + ((event.target && event.target.id) || ''));
    ['pointerdown','pointerup','touchstart','touchend','mousedown','mouseup','click','focus','focusin'].forEach((type) => {
      document.addEventListener(type, record, true);
    });
    </script>
    </body></html>
    """

    private static let nestedFixture = """
    <!doctype html><html><head></head><body style="margin:0">
    <div id="outer" style="position:absolute;left:24px;top:260px;width:160px;height:150px;background:#cde">
      <div id="inner" style="position:absolute;left:18px;top:18px;width:110px;height:100px;background:#9cf">
        <button id="leaf" style="width:80px;height:44px">Leaf</button>
      </div>
    </div>
    </body></html>
    """

    private static let coordinateFixture = """
    <!doctype html><html><head></head><body style="margin:0">
    <div id="other" style="position:absolute;left:80px;top:220px;width:100px;height:40px;background:#c33">Other</div>
    <div id="marker" style="position:absolute;left:80px;top:280px;width:100px;height:60px;background:#36c">Marker</div>
    <div style="height:2400px"></div>
    </body></html>
    """

    private static let composedTreeFixture = """
    <!doctype html><html><head></head><body style="margin:0">
    <div id="unassigned-host" style="position:absolute;left:24px;top:240px;width:320px;height:100px;background:#def">UNDISTRIBUTED_SECRET</div>
    <div id="assigned-host" style="position:absolute;left:24px;top:380px;width:320px;height:100px;background:#efd">
      <span slot="visible">ASSIGNED_VISIBLE</span><span>UNASSIGNED_SLOT_SECRET</span>
    </div>
    <div id="fallback-host" style="position:absolute;left:24px;top:520px;width:320px;height:100px;background:#fde"></div>
    <script>
      const unassigned = document.getElementById('unassigned-host').attachShadow({mode:'open'});
      unassigned.innerHTML = '<button style="margin:12px;width:140px;height:44px">Rendered button</button>';
      const assigned = document.getElementById('assigned-host').attachShadow({mode:'open'});
      assigned.innerHTML = '<slot name="visible"><span>INACTIVE_FALLBACK_SECRET</span></slot>';
      const fallback = document.getElementById('fallback-host').attachShadow({mode:'open'});
      fallback.innerHTML = '<slot><span>ACTIVE_FALLBACK</span></slot>';
    </script>
    </body></html>
    """

    private static let closedShadowLightDOMFixture = """
    <!doctype html><html><head></head><body style="margin:0">
    <div id="closed-ancestor" style="position:absolute;left:24px;top:240px;width:360px;height:220px;background:#eee">
      Visible ancestor
      <closed-leak-box id="closed-custom" style="position:absolute;left:12px;top:48px;width:150px;height:44px;display:block;background:orange">SECRET_CLOSED_CUSTOM</closed-leak-box>
      <div id="closed-ordinary" style="position:absolute;left:180px;top:48px;width:150px;height:44px;background:teal">SECRET_CLOSED_ORDINARY</div>
    </div>
    <script>
      class ClosedLeakBox extends HTMLElement {
        constructor() {
          super();
          const shadow = this.attachShadow({mode:'closed'});
          shadow.innerHTML = '<span>Visible custom</span>';
        }
      }
      if (!customElements.get('closed-leak-box')) customElements.define('closed-leak-box', ClosedLeakBox);
      const ordinary = document.getElementById('closed-ordinary');
      ordinary.attachShadow({mode:'closed'}).innerHTML = '<span>Visible ordinary</span>';
    </script>
    </body></html>
    """

    private static let digestFixture = """
    <!doctype html><html><head></head><body style="margin:0">
    <div id="digest-target" style="position:absolute;left:24px;top:240px;width:320px;min-height:80px;background:#def"></div>
    </body></html>
    """

    private static let sensitiveFixture = """
    <!doctype html><html><head></head><body style="margin:0">
    <div id="card" style="position:absolute;left:180px;top:240px;width:180px;height:180px;background:#eee">
      Visible card
      <span hidden>HIDDEN_SECRET</span>
      <span style="display:none">DISPLAY_NONE_SECRET</span>
      <span aria-hidden="true">ARIA_HIDDEN_SECRET</span>
      <div style="height:0;overflow:hidden">CLIP_SECRET</div>
      <span style="font-size:0">FONT_ZERO_SECRET</span>
      <span style="opacity:0.01;position:absolute;left:0;bottom:0">OPACITY_SECRET</span>
      <input id="password" type="password" value="p@ssw0rd" aria-label="pw-aria-secret" title="pw-title-secret" style="display:block;width:120px;height:28px">
      <input id="title-secret" type="text" title="pw-title-secret" style="position:absolute;left:20px;top:760px;width:140px;height:36px">
      <input type="text" value="user-typed-secret">
      <textarea>editable secret</textarea>
      <div contenteditable="true">editable block secret</div>
      <a id="token-link" href="https://example.com/callback?token=abc123&amp;x=1" onclick="window.__clicked=1">Link text</a>
    </div>
    <div id="open-host" style="position:absolute;left:20px;top:420px;width:150px;height:44px;background:#cfc"></div>
    <iframe id="frame" title="embedded" style="position:absolute;left:20px;top:600px;width:150px;height:44px" srcdoc="<p>IFRAME_SECRET</p>"></iframe>
    </body></html>
    """

    private func assertPickHitsMarker(
        in fixture: HostedHTML,
        controller: HTMLDOMPickController
    ) async throws {
        let css = try await cssRect(id: "marker", in: fixture.view)
        let metrics = try await metrics(in: fixture.view)
        let mapped = HTMLDOMViewportMapping.viewRect(fromCSSViewportRect: css, metrics: metrics)
        let point = CGPoint(x: mapped.midX, y: mapped.midY)
        let bounds = fixture.view.bounds
        guard bounds.insetBy(dx: 2, dy: 2).contains(point) else {
            Issue.record("Marker is offscreen after the viewport change. point \(point) css \(css) metrics \(metrics)")
            return
        }
        let serial = controller.completedLookupSerial
        controller.pick(at: point)
        let selected = await waitForCompletedLookup(controller, after: serial)
        #expect(selected?.elementId == "marker", "rejection \(String(describing: controller.lastRejection)) status \(controller.statusTextForTesting ?? "") selected \(selected?.tag ?? "nil")#\(selected?.elementId ?? "") css \(css) point \(point) metrics \(metrics)")
        guard selected?.elementId == "marker" else { return }
        let highlight = controller.highlightViewForTesting.frame
        #expect(abs(highlight.midX - mapped.midX) < 4, "highlight \(highlight) mapped \(mapped) css \(css) metrics \(metrics)")
        #expect(abs(highlight.midY - mapped.midY) < 4, "highlight \(highlight) mapped \(mapped) css \(css) metrics \(metrics)")
        let scale = metrics.viewPointsPerCSSPixel
        #expect(abs(highlight.width - css.width * scale) < 4, "highlight \(highlight) css \(css) scale \(scale)")
    }

    private func resetViewport(_ webView: WKWebView) async {
        webView.pageZoom = 1
        webView.scrollView.minimumZoomScale = 1
        webView.scrollView.maximumZoomScale = 1
        webView.scrollView.setZoomScale(1, animated: false)
        webView.scrollView.setContentOffset(.zero, animated: false)
        try? await Task.sleep(for: .milliseconds(80))
    }

    private func makeFixture(html: String, router: ReviewCommentSelectionRouter? = nil) async throws -> HostedHTML {
        let router = router ?? ReviewCommentSelectionRouter(dispatch: { _ in })
        let source = ReviewCommentSourceContext(sessionId: "session-html", surface: .fullScreenSource, filePath: "page.html")
        let view = HTMLRenderView(htmlString: html, reviewCommentRouter: router, sourceContext: source)
        let frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = frame
        } else {
            window = UIWindow(frame: frame)
        }
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        view.frame = host.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(view)
        host.view.layoutIfNeeded()
        view.layoutIfNeeded()
        let ready = await waitUntil { view.isRenderReady }
        #expect(ready)
        return HostedHTML(window: window, host: host, view: view)
    }

    private func makeStashHarness() throws -> StashHarness {
        let defaults = try makeDefaults()
        let store = ReviewCommentStore(defaults: defaults, keyPrefix: "html-dom-stash-\(UUID().uuidString)")
        let controller = ChatReviewCommentsController(store: store)
        let harness = StashHarness(store: store, controller: controller)
        let router = ReviewCommentSelectionRouter(
            dispatch: { request in harness.dispatches.append(request) },
            inlineSave: { body, request in
                harness.saves.append((body, request))
                return controller.save(body: body, request: request, localScopeId: "workspace", sessionId: "session-html") == nil
            },
            stash: controller
        )
        harness.router = router
        return harness
    }

    private func makeDefaults() throws -> UserDefaults {
        let name = "HTMLDOMElementAnnotationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func cssRect(id: String, in view: HTMLRenderView) async throws -> CGRect {
        var last = CGRect.zero
        for _ in 0..<20 {
            let json = try await pageString(
                """
                (() => { const node = document.getElementById('\(id)'); if (!node) return ''; const rect = node.getBoundingClientRect(); return JSON.stringify({x:rect.x,y:rect.y,width:rect.width,height:rect.height}); })()
                """,
                in: view
            )
            last = try decodeRect(json)
            if last.width > 1, last.height > 1 { return last }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return last
    }

    private func contentWorldRect(id: String, in view: HTMLRenderView) async throws -> CGRect {
        var last = CGRect.zero
        for _ in 0..<20 {
            last = try await readContentWorldRect(id: id, in: view)
            if last.width > 1, last.height > 1 { return last }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return last
    }

    private func readContentWorldRect(id: String, in view: HTMLRenderView) async throws -> CGRect {
        let result = try await view.webViewForTesting.callAsyncJavaScript(
            """
            const node = document.getElementById(id);
            if (!node) return null;
            const rect = node.getBoundingClientRect();
            return {x:rect.x,y:rect.y,width:rect.width,height:rect.height};
            """,
            arguments: ["id": id],
            in: nil,
            contentWorld: HTMLDOMWebKitLookupClient.contentWorld
        )
        let dict = try #require(HTMLDOMSanitizer.dictionary(result))
        return CGRect(
            x: HTMLDOMSanitizer.cgFloat(dict["x"]) ?? 0,
            y: HTMLDOMSanitizer.cgFloat(dict["y"]) ?? 0,
            width: HTMLDOMSanitizer.cgFloat(dict["width"]) ?? 0,
            height: HTMLDOMSanitizer.cgFloat(dict["height"]) ?? 0
        )
    }

    private func metrics(in view: HTMLRenderView) async throws -> HTMLDOMViewportMetrics {
        let webView = view.webViewForTesting
        let scale = try await pageNumber("window.visualViewport ? window.visualViewport.scale : 1", in: view)
        let offsetX = try await pageNumber("window.visualViewport ? window.visualViewport.offsetLeft : 0", in: view)
        let offsetY = try await pageNumber("window.visualViewport ? window.visualViewport.offsetTop : 0", in: view)
        return HTMLDOMViewportMetrics(
            pageZoom: webView.pageZoom > 0 ? webView.pageZoom : 1,
            scrollZoomScale: webView.scrollView.zoomScale > 0 ? webView.scrollView.zoomScale : 1,
            visualViewportScale: scale > 0 ? scale : 1,
            visualViewportOffset: CGPoint(x: offsetX, y: offsetY),
            viewportOriginInView: CGPoint(
                x: webView.scrollView.adjustedContentInset.left,
                y: webView.scrollView.adjustedContentInset.top
            ),
            contentOffset: webView.scrollView.contentOffset
        )
    }

    private func viewPoint(for rect: CGRect, in view: HTMLRenderView) async throws -> CGPoint {
        let mapped = HTMLDOMViewportMapping.viewRect(fromCSSViewportRect: rect, metrics: try await metrics(in: view))
        return CGPoint(x: mapped.midX, y: mapped.midY)
    }

    private func pageString(
        _ script: String,
        arguments: [String: Any] = [:],
        in view: HTMLRenderView
    ) async throws -> String {
        let value: Any?
        if arguments.isEmpty {
            value = try await view.webViewForTesting.evaluateJavaScript(script)
        } else {
            value = try await view.webViewForTesting.callAsyncJavaScript(
                script,
                arguments: arguments,
                in: nil,
                contentWorld: .page
            )
        }
        if let string = value as? String { return string }
        if value == nil || value is NSNull { return "" }
        return String(describing: value)
    }

    private func pageNumber(_ script: String, in view: HTMLRenderView) async throws -> CGFloat {
        let value = try await view.webViewForTesting.evaluateJavaScript(script)
        if let number = value as? NSNumber { return CGFloat(truncating: number) }
        return 0
    }

    private func decodeRect(_ json: String) throws -> CGRect {
        let data = try #require(json.data(using: .utf8))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return CGRect(
            x: HTMLDOMSanitizer.cgFloat(object["x"]) ?? 0,
            y: HTMLDOMSanitizer.cgFloat(object["y"]) ?? 0,
            width: HTMLDOMSanitizer.cgFloat(object["width"]) ?? 0,
            height: HTMLDOMSanitizer.cgFloat(object["height"]) ?? 0
        )
    }

    private func pickAndWait(_ controller: HTMLDOMPickController, at point: CGPoint) async -> HTMLDOMSanitizedElement? {
        let serial = controller.completedLookupSerial
        controller.pick(at: point)
        return await waitForCompletedLookup(controller, after: serial)
    }

    private func waitForCompletedLookup(
        _ controller: HTMLDOMPickController,
        after serial: Int
    ) async -> HTMLDOMSanitizedElement? {
        for _ in 0..<80 {
            if controller.completedLookupSerial > serial {
                return controller.snapshotForTesting?.element
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return controller.snapshotForTesting?.element
    }

    private func waitForElement(
        id: String,
        controller: HTMLDOMPickController,
        after serial: Int? = nil
    ) async -> HTMLDOMSanitizedElement? {
        if let serial {
            let element = await waitForCompletedLookup(controller, after: serial)
            return element?.elementId == id ? element : element
        }
        for _ in 0..<80 {
            if let element = controller.snapshotForTesting?.element, element.elementId == id {
                return element
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return controller.snapshotForTesting?.element
    }

    private func waitForSnapshot(
        _ controller: HTMLDOMPickController,
        where predicate: (HTMLDOMSanitizedElement) -> Bool = { _ in true }
    ) async -> HTMLDOMSanitizedElement? {
        for _ in 0..<80 {
            if let element = controller.snapshotForTesting?.element, predicate(element) {
                return element
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return controller.snapshotForTesting?.element
    }

    private func waitForStatus(containing text: String, controller: HTMLDOMPickController) async -> Bool {
        await waitUntil { controller.statusTextForTesting?.contains(text) == true }
    }

    private func waitForView(_ identifier: String, in root: UIView, attempts: Int = 80) async -> UIView? {
        for _ in 0..<attempts {
            if let found = find(identifier, in: root) { return found }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func waitForComposerOrStale(
        _ controller: HTMLDOMPickController,
        stale: Int,
        in root: UIView
    ) async -> UIView? {
        for _ in 0..<80 {
            if let composer = find("review-comment.inline-composer", in: root) { return composer }
            if controller.staleLookupCount > stale { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return find("review-comment.inline-composer", in: root)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<80 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    private func find(_ identifier: String, in root: UIView) -> UIView? {
        if root.accessibilityIdentifier == identifier { return root }
        for subview in root.subviews {
            if let found = find(identifier, in: subview) { return found }
        }
        return nil
    }

    private func elementPayload(text: String, extraAttributes: [String: String] = [:]) -> [String: Any] {
        var attributes: [String: Any] = ["id": "save"]
        for (key, value) in extraAttributes { attributes[key] = value }
        return [
            "tagName": "button",
            "attributes": attributes,
            "visibleText": text,
            "accessibleName": text,
            "nodeToken": "fixture-node",
            "textDigest": HTMLDOMSourceIdentity.sha256Hex(text),
            "locator": [["tag": "html", "siblingIndex": 0, "entersOpenShadow": false]],
            "bounds": ["x": 0, "y": 0, "width": 20, "height": 10],
            "isConnected": true,
            "hasParent": true,
        ]
    }

    private func sanitizedElement(text: String) -> HTMLDOMSanitizedElement {
        let result = HTMLDOMSanitizer.sanitize(elementPayload(text: text))
        guard case .success(let element) = result else {
            preconditionFailure("expected sanitized element")
        }
        return element
    }
}

private struct HostedHTML {
    let window: UIWindow
    let host: UIViewController
    let view: HTMLRenderView
}

@MainActor
private final class ResumeGate {
    private var resumed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if resumed { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        resumed = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum FirstResponderBox {
    nonisolated(unsafe) static weak var current: UIResponder?
}

extension UIResponder {
    @objc func oppiTestsCaptureFirstResponder() {
        FirstResponderBox.current = self
    }
}

@MainActor
private func currentFirstResponder() -> UIResponder? {
    FirstResponderBox.current = nil
    UIApplication.shared.sendAction(#selector(UIResponder.oppiTestsCaptureFirstResponder), to: nil, from: nil, for: nil)
    return FirstResponderBox.current
}

@MainActor
private func isDescendantResponder(_ responder: UIResponder, of view: UIView) -> Bool {
    if responder === view { return true }
    guard let responderView = responder as? UIView else { return false }
    return responderView.isDescendant(of: view)
}

@MainActor
private final class StashHarness {
    let store: ReviewCommentStore
    let controller: ChatReviewCommentsController
    var router: ReviewCommentSelectionRouter!
    var saves: [(String, ReviewCommentSelectionRequest)] = []
    var dispatches: [ReviewCommentSelectionRequest] = []

    init(store: ReviewCommentStore, controller: ChatReviewCommentsController) {
        self.store = store
        self.controller = controller
    }
}
