import UIKit
import WebKit

/// Read-only DOM lookup in a dedicated content world. Namespace isolation is
/// not trust: returned values are sanitized again before any comment is staged.
@MainActor
final class HTMLDOMWebKitLookupClient {
    static let contentWorldName = "oppi.html-dom-annotation"
    static let contentWorld = WKContentWorld.world(name: contentWorldName)

    weak var webView: WKWebView?
    var beforeCallForTesting: (@MainActor (_ mode: String) async -> Void)?

    func viewport() async throws -> (scale: CGFloat, offset: CGPoint) {
        let result = try await call(mode: "viewport", x: 0, y: 0, locator: [])
        let viewport = HTMLDOMSanitizer.dictionary(result["viewport"]) ?? result
        let scale = HTMLDOMSanitizer.cgFloat(viewport["scale"]) ?? 1
        let offset = CGPoint(
            x: HTMLDOMSanitizer.cgFloat(viewport["offsetLeft"]) ?? 0,
            y: HTMLDOMSanitizer.cgFloat(viewport["offsetTop"]) ?? 0
        )
        return (scale > 0 ? scale : 1, offset)
    }

    func lookup(
        mode: String,
        cssPoint: CGPoint,
        locator: [HTMLDOMLocatorStep]
    ) async throws -> [String: Any] {
        try await call(mode: mode, x: cssPoint.x, y: cssPoint.y, locator: locator)
    }

    private func call(
        mode: String,
        x: CGFloat,
        y: CGFloat,
        locator: [HTMLDOMLocatorStep]
    ) async throws -> [String: Any] {
        guard let webView else { throw HTMLDOMLookupClientError.missingWebView }
        if let hook = beforeCallForTesting {
            await hook(mode)
        }
        let steps: [[String: Any]] = locator.map {
            [
                "tag": $0.tag,
                "siblingIndex": $0.siblingIndex,
                "entersOpenShadow": $0.entersOpenShadow,
            ]
        }
        let result = try await webView.callAsyncJavaScript(
            Self.lookupFunction,
            arguments: [
                "mode": mode,
                "x": Double(x),
                "y": Double(y),
                "locator": steps,
            ],
            in: nil,
            contentWorld: Self.contentWorld
        )
        guard let dict = HTMLDOMSanitizer.dictionary(result) else {
            throw HTMLDOMLookupClientError.malformedResult
        }
        return dict
    }

    static let lookupFunction = """
    const maxText = 240;
    const maxVisits = 400;
    const frameTags = { iframe: 1, frame: 1, object: 1, embed: 1, fencedframe: 1 };

    function viewportInfo() {
      const visual = window.visualViewport;
      return {
        scale: visual && visual.scale ? visual.scale : 1,
        offsetLeft: visual ? visual.offsetLeft : 0,
        offsetTop: visual ? visual.offsetTop : 0,
        innerWidth: window.innerWidth,
        innerHeight: window.innerHeight
      };
    }

    function tagNameOf(el) {
      return el && el.tagName ? el.tagName.toLowerCase() : "";
    }

    function isSensitive(el) {
      if (!el || el.nodeType !== 1) return false;
      const tag = tagNameOf(el);
      if (tag === "input" || tag === "textarea" || tag === "select" || tag === "option") return true;
      if (el.isContentEditable) return true;
      const type = (el.getAttribute("type") || "").toLowerCase();
      return type === "password" || type === "hidden";
    }

    function identityState() {
      const key = "__oppiHTMLDOMIdentity";
      if (!globalThis[key]) {
        globalThis[key] = { next: 1, tokens: new WeakMap() };
      }
      return globalThis[key];
    }

    function tokenFor(el) {
      const state = identityState();
      let token = state.tokens.get(el);
      if (!token) {
        token = String(state.next++);
        state.tokens.set(el, token);
      }
      return token;
    }

    function textDigest(value) {
      if (!globalThis.TextEncoder) throw new Error("SHA-256 unavailable");
      const bytes = new TextEncoder().encode(value);
      if (bytes.length > 1048576) throw new Error("SHA-256 input too large");
      const paddedLength = Math.ceil((bytes.length + 9) / 64) * 64;
      const padded = new Uint8Array(paddedLength);
      padded.set(bytes);
      padded[bytes.length] = 0x80;
      const view = new DataView(padded.buffer);
      const bitLength = bytes.length * 8;
      view.setUint32(paddedLength - 8, Math.floor(bitLength / 0x100000000), false);
      view.setUint32(paddedLength - 4, bitLength >>> 0, false);
      const state = new Uint32Array([
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
      ]);
      const constants = new Uint32Array([
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
      ]);
      const words = new Uint32Array(64);
      const rotateRight = (word, count) => (word >>> count) | (word << (32 - count));
      for (let offset = 0; offset < paddedLength; offset += 64) {
        for (let i = 0; i < 16; i++) words[i] = view.getUint32(offset + i * 4, false);
        for (let i = 16; i < 64; i++) {
          const s0 = rotateRight(words[i - 15], 7) ^ rotateRight(words[i - 15], 18) ^ (words[i - 15] >>> 3);
          const s1 = rotateRight(words[i - 2], 17) ^ rotateRight(words[i - 2], 19) ^ (words[i - 2] >>> 10);
          words[i] = (words[i - 16] + s0 + words[i - 7] + s1) >>> 0;
        }
        let a=state[0], b=state[1], c=state[2], d=state[3];
        let e=state[4], f=state[5], g=state[6], h=state[7];
        for (let i = 0; i < 64; i++) {
          const sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
          const choice = (e & f) ^ (~e & g);
          const temp1 = (h + sum1 + choice + constants[i] + words[i]) >>> 0;
          const sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
          const majority = (a & b) ^ (a & c) ^ (b & c);
          const temp2 = (sum0 + majority) >>> 0;
          h=g; g=f; f=e; e=(d + temp1) >>> 0; d=c; c=b; b=a; a=(temp1 + temp2) >>> 0;
        }
        state[0]=(state[0]+a)>>>0; state[1]=(state[1]+b)>>>0;
        state[2]=(state[2]+c)>>>0; state[3]=(state[3]+d)>>>0;
        state[4]=(state[4]+e)>>>0; state[5]=(state[5]+f)>>>0;
        state[6]=(state[6]+g)>>>0; state[7]=(state[7]+h)>>>0;
      }
      return Array.from(state, word => word.toString(16).padStart(8, "0")).join("");
    }

    function clipsOverflow(style) {
      if (!style) return false;
      return style.overflow === "hidden" || style.overflow === "clip"
        || style.overflowX === "hidden" || style.overflowX === "clip"
        || style.overflowY === "hidden" || style.overflowY === "clip";
    }

    function isHidden(el) {
      if (!el || el.nodeType !== 1) return true;
      const tag = tagNameOf(el);
      if (tag === "script" || tag === "style" || tag === "template" || tag === "noscript") return true;
      if (el.hasAttribute("hidden")) return true;
      const aria = (el.getAttribute("aria-hidden") || "").toLowerCase();
      if (aria === "true") return true;
      if (tag === "input" && (el.getAttribute("type") || "").toLowerCase() === "hidden") return true;
      const style = getComputedStyle(el);
      if (!style) return false;
      if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return true;
      const opacity = parseFloat(style.opacity || "1");
      if (!Number.isNaN(opacity) && opacity <= 0.02) return true;
      const fontSize = parseFloat(style.fontSize || "16");
      if (!Number.isNaN(fontSize) && fontSize === 0) return true;
      if (clipsOverflow(style) && (el.clientWidth <= 0 || el.clientHeight <= 0)) return true;
      return false;
    }

    function visuallySuppressed(el) {
      let current = el;
      let guardCount = 0;
      while (current && current.nodeType === 1 && guardCount++ < 40) {
        if (isHidden(current)) return true;
        const root = current.getRootNode && current.getRootNode();
        if (!current.parentElement && root && root.host) current = root.host;
        else current = current.parentElement;
      }
      return false;
    }

    function descriptiveAttribute(el, name) {
      if (isSensitive(el)) return null;
      return allowedAttribute(el, name);
    }

    function ancestorSensitive(el) {
      let current = el;
      while (current && current.nodeType === 1) {
        if (isSensitive(current)) return true;
        const root = current.getRootNode && current.getRootNode();
        if (!current.parentElement && root && root.host) {
          current = root.host;
        } else {
          current = current.parentElement;
        }
      }
      return false;
    }

    async function visibleText(el) {
      let out = "";
      let visits = 0;
      let truncated = false;
      const visited = new WeakSet();
      function assignedLightChildren(node) {
        const nodes = [];
        let sawAssigned = false;
        const children = node.childNodes || [];
        for (let i = 0; i < children.length; i++) {
          if (children[i].assignedSlot) {
            sawAssigned = true;
            nodes.push(children[i]);
          }
        }
        return { sawAssigned, nodes };
      }
      function composedChildren(node) {
        if (node && node.nodeType === 1) {
          if (tagNameOf(node) === "slot") {
            const assigned = node.assignedNodes ? node.assignedNodes({ flatten: true }) : [];
            if (assigned.length) return assigned;
          }
          // A shadow host renders its shadow tree, not undistributed light DOM.
          if (node.shadowRoot) return node.shadowRoot.childNodes || [];
          // Closed shadow: light DOM is composed only when assigned to a slot.
          const slotted = assignedLightChildren(node);
          if (slotted.sawAssigned) return slotted.nodes;
        }
        return node && node.childNodes ? node.childNodes : [];
      }
      function isPaintedTextNode(node) {
        try {
          const range = document.createRange();
          range.selectNode(node);
          const rects = range.getClientRects();
          for (let i = 0; i < rects.length; i++) {
            if (rects[i].width > 0 || rects[i].height > 0) return true;
          }
          return false;
        } catch (e) {
          return false;
        }
      }
      function walk(node) {
        if (truncated || !node || visited.has(node)) return;
        visited.add(node);
        if (visits++ > maxVisits) {
          truncated = true;
          return;
        }
        if (node.nodeType === 3) {
          const parent = node.parentElement;
          if (!parent || visuallySuppressed(parent) || ancestorSensitive(parent)) return;
          if (!isPaintedTextNode(node)) return;
          out += node.nodeValue || "";
          return;
        }
        if (node.nodeType !== 1 && node.nodeType !== 11) return;
        if (node.nodeType === 1 && (isSensitive(node) || visuallySuppressed(node))) return;
        if (node.nodeType === 1 && tagNameOf(node) === "details" && !node.open) {
          const summary = node.querySelector(":scope > summary");
          if (summary) walk(summary);
          return;
        }
        const children = composedChildren(node);
        for (let i = 0; i < children.length; i++) walk(children[i]);
      }
      walk(el);
      const normalized = out.replace(/\\s+/g, " ").trim();
      return {
        text: normalized.slice(0, maxText),
        digest: textDigest(normalized),
        truncated: truncated
      };
    }

    // Readable order among rendered, composed elements distinguishes repeated
    // controls in separate groups without exposing their private DOM locators.
    function tagOrdinal(el) {
      const tag = tagNameOf(el);
      const stack = [document.documentElement];
      let visits = 0, count = 0, position = 0;
      while (stack.length) {
        const node = stack.pop();
        if (++visits > 10000) return null;
        // Follow composed descendants, not a hidden slot's assigned controls.
        if (node.nodeType === 1 && isHidden(node)) continue;
        if (node.nodeType === 1 && tagNameOf(node) === tag && !visuallySuppressed(node)) {
          const rects = node.getClientRects();
          for (let i = 0; i < rects.length; i++) {
            if (rects[i].width <= 0 || rects[i].height <= 0) continue;
            count++;
            if (node === el) position = count;
            break;
          }
        }
        let children = node.children || [];
        if (node.shadowRoot) {
          children = node.shadowRoot.children || [];
        } else if (node.nodeType === 1 && tagNameOf(node) === "slot") {
          const assigned = node.assignedElements ? node.assignedElements({ flatten: true }) : [];
          if (assigned.length) children = assigned;
        }
        for (let i = children.length - 1; i >= 0; i--) stack.push(children[i]);
      }
      return count > 1 && position > 0 ? position : null;
    }

    function siblingIndex(el) {
      const parent = el.parentElement;
      if (parent) return Array.prototype.indexOf.call(parent.children, el);
      const root = el.getRootNode();
      if (root && root.children) return Array.prototype.indexOf.call(root.children, el);
      return 0;
    }

    function locatorSteps(el) {
      const chain = [];
      let current = el;
      let guard = 0;
      while (current && current.nodeType === 1 && guard++ < 32) {
        const root = current.getRootNode();
        const inShadow = !!(root && root.host && root.nodeType === 11);
        const entersOpenShadow = inShadow && !current.parentElement;
        chain.push({
          tag: tagNameOf(current),
          siblingIndex: Math.max(0, siblingIndex(current)),
          entersOpenShadow: entersOpenShadow
        });
        if (entersOpenShadow) current = root.host;
        else current = current.parentElement;
      }
      chain.reverse();
      return chain;
    }

    function resolveLocator(steps) {
      if (!Array.isArray(steps) || !steps.length) return null;
      if (!document.documentElement || steps[0].tag !== "html") return null;
      let current = document.documentElement;
      for (let i = 1; i < steps.length; i++) {
        const step = steps[i] || {};
        const container = step.entersOpenShadow ? current.shadowRoot : current;
        if (!container || !container.children) return null;
        const child = container.children[step.siblingIndex];
        if (!child || tagNameOf(child) !== step.tag) return null;
        current = child;
      }
      return current;
    }

    function parentOf(el) {
      if (!el || el === document.documentElement) return null;
      if (el.parentElement) return el.parentElement;
      const root = el.getRootNode();
      if (root && root.host) return root.host;
      return null;
    }

    function deepest(x, y) {
      let el = document.elementFromPoint(x, y);
      const seen = [];
      while (el && el.shadowRoot && seen.indexOf(el) === -1) {
        seen.push(el);
        const inner = el.shadowRoot.elementFromPoint(x, y);
        if (!inner || inner === el) break;
        el = inner;
      }
      return el;
    }

    function limitationFor(el) {
      if (!el) return null;
      const tag = tagNameOf(el);
      if (frameTags[tag]) return "embeddedFrame";
      if (tag.indexOf("-") !== -1 && !el.shadowRoot) return "closedShadowHost";
      return null;
    }

    function allowedAttribute(el, name) {
      if (!el.hasAttribute(name)) return null;
      const value = el.getAttribute(name);
      if (value == null) return null;
      return String(value).slice(0, 200);
    }

    async function describe(el) {
      if (!el || el.nodeType !== 1) return { found: false, viewport: viewportInfo() };
      const text = await visibleText(el);
      const aria = descriptiveAttribute(el, "aria-label");
      const alt = descriptiveAttribute(el, "alt");
      const title = descriptiveAttribute(el, "title");
      const accessible = aria || alt || title || "";
      const rect = el.getBoundingClientRect();
      return {
        found: true,
        truncated: text.truncated,
        nodeToken: tokenFor(el),
        textDigest: text.digest,
        tagName: tagNameOf(el),
        tagOrdinal: tagOrdinal(el),
        attributes: {
          id: descriptiveAttribute(el, "id"),
          class: descriptiveAttribute(el, "class"),
          role: descriptiveAttribute(el, "role"),
          "aria-label": aria,
          alt: alt,
          title: title,
          type: allowedAttribute(el, "type"),
          href: allowedAttribute(el, "href"),
          src: allowedAttribute(el, "src")
        },
        accessibleName: String(accessible).slice(0, 120),
        visibleText: text.text,
        isSensitive: isSensitive(el),
        locator: locatorSteps(el),
        limitation: limitationFor(el),
        isConnected: !!el.isConnected,
        hasParent: !!parentOf(el),
        bounds: { x: rect.x, y: rect.y, width: rect.width, height: rect.height },
        viewport: viewportInfo()
      };
    }

    if (mode === "viewport") {
      return { found: true, viewport: viewportInfo() };
    }
    if (mode === "parent" || mode === "revalidate") {
      const el = resolveLocator(locator);
      if (!el || !el.isConnected) return { found: false, viewport: viewportInfo() };
      if (mode === "parent") {
        const parent = parentOf(el);
        if (!parent) return { found: false, viewport: viewportInfo() };
        return await describe(parent);
      }
      return await describe(el);
    }
    return await describe(deepest(x, y));
    """
}

enum HTMLDOMLookupClientError: Error {
    case missingWebView
    case malformedResult
}

/// Native shield that owns pick touches before WebKit. It does not use a
/// gesture recognizer and does not forward or synthesize page events.
final class HTMLDOMPickShieldView: UIView {
    var onTap: ((CGPoint) -> Void)?
    private var startPoint: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        isHidden = true
        isExclusiveTouch = true
        isAccessibilityElement = true
        accessibilityIdentifier = "html.pick.shield"
        accessibilityLabel = "Element pick shield"
        accessibilityHint = "Scrolling is paused. Tap an element to select it, or tap Browse to scroll."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setPicking(_ picking: Bool) {
        isUserInteractionEnabled = picking
        isHidden = !picking
        accessibilityElementsHidden = !picking
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        startPoint = touches.first?.location(in: self)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let start = startPoint, let point = touches.first?.location(in: self) else { return }
        startPoint = nil
        let dx = point.x - start.x
        let dy = point.y - start.y
        guard (dx * dx) + (dy * dy) <= 144 else { return }
        onTap?(point)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        startPoint = nil
    }
}

final class HTMLDOMHighlightView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        backgroundColor = UIColor.systemBlue.withAlphaComponent(0.18)
        layer.borderWidth = 2
        layer.cornerRadius = 4
        isAccessibilityElement = true
        accessibilityIdentifier = "html.pick.highlight"
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: Self, _) in
            view.updateBorderColor()
        }
        updateBorderColor()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateBorderColor()
    }

    private func updateBorderColor() {
        layer.borderColor = UIColor.systemBlue.resolvedColor(with: traitCollection).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ rect: CGRect, label: String) {
        frame = rect.integral
        isHidden = rect.isNull || rect.isEmpty
        accessibilityLabel = label
    }

    func hide() {
        isHidden = true
        accessibilityLabel = nil
    }
}

final class HTMLDOMPickChromeView: UIView {
    var onEnterPick: (() -> Void)?
    var onExitPick: (() -> Void)?
    var onSelectParent: (() -> Void)?
    var onComment: (() -> Void)?

    let enterButton = UIButton(type: .system)
    let exitButton = UIButton(type: .system)
    let parentButton = UIButton(type: .system)
    let commentButton = UIButton(type: .system)
    let bannerLabel = UILabel()
    let statusLabel = UILabel()
    let selectionLabel = UILabel()
    private let stack = UIStackView()
    private var isAvailable = false
    var usesExternalControls = false {
        didSet { if !isAvailable || usesExternalControls { isHidden = true } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.94)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        isHidden = true

        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        configure(enterButton, title: "Pick Element", identifier: "html.pick.enter")
        enterButton.accessibilityHint = "Pause browsing and choose a rendered element. Scrolling stays paused until you exit pick mode."
        enterButton.addAction(UIAction { [weak self] _ in self?.onEnterPick?() }, for: .touchUpInside)

        configure(exitButton, title: "Browse", identifier: "html.pick.exit")
        exitButton.accessibilityHint = "Leave pick mode and resume scrolling."
        exitButton.addAction(UIAction { [weak self] _ in self?.onExitPick?() }, for: .touchUpInside)

        bannerLabel.text = "Pick mode pauses scrolling. Browse to scroll."
        bannerLabel.numberOfLines = 0
        bannerLabel.font = .preferredFont(forTextStyle: .footnote)
        bannerLabel.accessibilityIdentifier = "html.pick.banner"
        bannerLabel.isHidden = true

        selectionLabel.numberOfLines = 2
        selectionLabel.font = .preferredFont(forTextStyle: .subheadline)
        selectionLabel.accessibilityIdentifier = "html.pick.label"
        selectionLabel.isHidden = true

        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityIdentifier = "html.pick.status"
        statusLabel.isHidden = true

        configure(parentButton, title: "Select Parent", identifier: "html.pick.parent")
        parentButton.addAction(UIAction { [weak self] _ in self?.onSelectParent?() }, for: .touchUpInside)
        configure(commentButton, title: "Comment", identifier: "html.pick.comment")
        commentButton.addAction(UIAction { [weak self] _ in self?.onComment?() }, for: .touchUpInside)

        let actions = UIStackView(arrangedSubviews: [parentButton, commentButton])
        actions.axis = .horizontal
        actions.spacing = 12
        actions.isHidden = true
        actions.accessibilityIdentifier = "html.pick.actions"

        stack.addArrangedSubview(enterButton)
        stack.addArrangedSubview(exitButton)
        stack.addArrangedSubview(bannerLabel)
        stack.addArrangedSubview(selectionLabel)
        stack.addArrangedSubview(actions)
        stack.addArrangedSubview(statusLabel)
        showBrowse()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setAvailable(_ available: Bool) {
        isAvailable = available
        isHidden = !available || usesExternalControls
    }

    func showBrowse() {
        isHidden = !isAvailable || usesExternalControls
        enterButton.isHidden = usesExternalControls
        exitButton.isHidden = true
        bannerLabel.isHidden = true
        selectionLabel.isHidden = true
        actionRow?.isHidden = true
        setStatus(nil)
    }

    func showPick() {
        isHidden = !isAvailable
        enterButton.isHidden = true
        exitButton.isHidden = usesExternalControls
        bannerLabel.isHidden = false
        selectionLabel.isHidden = true
        actionRow?.isHidden = true
    }

    func showSelection(label: String, parentEnabled: Bool) {
        selectionLabel.text = label
        // The full-screen menu owns Select Parent and the target owns Comment;
        // do not place a second card on top of the selected HTML.
        isHidden = usesExternalControls
        bannerLabel.isHidden = usesExternalControls
        selectionLabel.isHidden = usesExternalControls
        actionRow?.isHidden = usesExternalControls
        commentButton.isHidden = usesExternalControls
        parentButton.isEnabled = parentEnabled
        commentButton.isEnabled = true
    }

    func updateSelectionLabel(_ label: String) { selectionLabel.text = label }

    func clearSelection() {
        selectionLabel.text = nil
        selectionLabel.isHidden = true
        actionRow?.isHidden = true
        commentButton.isEnabled = false
        parentButton.isEnabled = false
    }

    func setStatus(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        statusLabel.text = trimmed.isEmpty ? nil : trimmed
        statusLabel.isHidden = trimmed.isEmpty
        if usesExternalControls, selectionLabel.text != nil {
            isHidden = trimmed.isEmpty
        }
    }

    func setReady(_ ready: Bool) {
        enterButton.isEnabled = ready
    }

    private var actionRow: UIStackView? {
        stack.arrangedSubviews.compactMap { $0 as? UIStackView }.first
    }

    private func configure(_ button: UIButton, title: String, identifier: String) {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0)
        config.titleAlignment = .leading
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .headline)
            return outgoing
        }
        button.configuration = config
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }
}

@MainActor
final class HTMLDOMPickController {
    private let client: HTMLDOMWebKitLookupClient
    private let shield = HTMLDOMPickShieldView()
    private let highlight = HTMLDOMHighlightView()
    private let chrome = HTMLDOMPickChromeView()
    private weak var host: HTMLRenderView?
    private weak var webView: WKWebView?

    private var router: ReviewCommentSelectionRouter?
    private var sourceContext: ReviewCommentSourceContext?
    private var snapshot: HTMLDOMSelectionSnapshot?
    private var activeLookupID: UUID?
    private var activePickSessionID: UUID?
    private(set) var navigationGeneration: UInt64 = 0
    private(set) var loadedSourceSHA256 = ""
    private(set) var isPicking = false
    var onPickStateChange: ((Bool, Bool) -> Void)?
    var onSelectionGeometryChange: (() -> Void)?
    func selectedTargetRect(in view: UIView) -> CGRect? {
        guard snapshot != nil, !highlight.isHidden, let host else { return nil }
        return highlight.convert(highlight.bounds, to: view)
    }
    var usesExternalPickControls: Bool {
        get { chrome.usesExternalControls }
        set { chrome.usesExternalControls = newValue }
    }
    var hasSelection: Bool { snapshot != nil }
    var canSelectParent: Bool { snapshot?.element.hasParent == true }
    var canPick: Bool { router != nil && sourceContext != nil && host?.isRenderReady == true }
    private(set) var staleLookupCount = 0
    private(set) var completedLookupSerial = 0
    private(set) var lastRejection: HTMLDOMSelectionRejection?
    var beforeLookupResumeForTesting: (@MainActor () async -> Void)?

    init(webView: WKWebView, client: HTMLDOMWebKitLookupClient = HTMLDOMWebKitLookupClient()) {
        self.webView = webView
        self.client = client
        client.webView = webView
        shield.onTap = { [weak self] point in
            self?.pick(at: point)
        }
        chrome.onEnterPick = { [weak self] in self?.enterPick() }
        chrome.onExitPick = { [weak self] in self?.exitPick() }
        chrome.onSelectParent = { [weak self] in self?.selectParent() }
        chrome.onComment = { [weak self] in self?.comment() }
    }

    func attach(to host: HTMLRenderView) {
        self.host = host
        shield.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(shield)
        NSLayoutConstraint.activate([
            shield.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            shield.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            shield.topAnchor.constraint(equalTo: host.topAnchor),
            shield.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        highlight.translatesAutoresizingMaskIntoConstraints = true
        host.addSubview(highlight)
        chrome.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(greaterThanOrEqualTo: host.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            chrome.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            chrome.trailingAnchor.constraint(equalTo: host.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            chrome.topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 8),
        ])
        host.bringSubviewToFront(shield)
        host.bringSubviewToFront(highlight)
        host.bringSubviewToFront(chrome)
    }

    func configure(router: ReviewCommentSelectionRouter?, sourceContext: ReviewCommentSourceContext?) {
        self.router = router
        self.sourceContext = sourceContext
        let available = router != nil && sourceContext != nil
        chrome.setAvailable(available)
        if !available {
            exitPick()
        }
        chrome.setReady(host?.isRenderReady == true)
    }

    func setLoadedSource(_ html: String) {
        loadedSourceSHA256 = HTMLDOMSourceIdentity.sha256Hex(html)
    }

    func noteDocumentChange() {
        navigationGeneration &+= 1
        activeLookupID = nil
        clearSelection(status: isPicking ? HTMLDOMSelectionRejection.staleGeneration.userMessage : nil)
    }

    func renderReadyChanged() {
        chrome.setReady(host?.isRenderReady == true)
    }

    func refreshHighlightAfterViewportChange() {
        guard isPicking, let snapshot else { return }
        refreshGeometry(for: snapshot)
    }

    func enterPick() {
        guard router != nil, sourceContext != nil, host?.isRenderReady == true else { return }
        resignPageEditing()
        isPicking = true
        activePickSessionID = UUID()
        activeLookupID = nil
        webView?.isUserInteractionEnabled = false
        shield.setPicking(true)
        chrome.showPick()
        onPickStateChange?(true, false)
        host?.bringSubviewToFront(shield)
        host?.bringSubviewToFront(highlight)
        host?.bringSubviewToFront(chrome)
    }

    func exitPick() {
        isPicking = false
        activePickSessionID = nil
        activeLookupID = nil
        webView?.isUserInteractionEnabled = true
        shield.setPicking(false)
        clearSelection(status: nil)
        chrome.showBrowse()
        onPickStateChange?(false, false)
    }

    private func resignPageEditing() {
        webView?.endEditing(true)
        host?.window?.endEditing(true)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func pick(at point: CGPoint) {
        guard isPicking else { return }
        startLookup(mode: "hit", point: point, locator: [])
    }

    func selectParent() {
        guard let snapshot else { return }
        startLookup(mode: "parent", point: .zero, locator: snapshot.element.locator)
    }

    func comment() {
        guard let openedSnapshot = snapshot,
              let openedSource = sourceContext,
              let openedPickSessionID = activePickSessionID,
              router != nil else { return }
        let openedGeneration = navigationGeneration
        let openedSessionID = openedSource.sessionId
        let openedSourceHash = loadedSourceSHA256
        let lookupID = UUID()
        activeLookupID = lookupID
        Task { @MainActor in
            if let hook = beforeLookupResumeForTesting {
                await hook()
            }
            guard self.commentOperationIsCurrent(
                lookupID: lookupID,
                generation: openedGeneration,
                sessionId: openedSessionID,
                sourceHash: openedSourceHash,
                pickSessionID: openedPickSessionID
            ) else {
                self.finishSuperseded(lookupID: lookupID)
                return
            }
            do {
                let raw = try await self.client.lookup(
                    mode: "revalidate",
                    cssPoint: .zero,
                    locator: openedSnapshot.element.locator
                )
                guard self.commentOperationIsCurrent(
                    lookupID: lookupID,
                    generation: openedGeneration,
                    sessionId: openedSessionID,
                    sourceHash: openedSourceHash,
                    pickSessionID: openedPickSessionID
                ) else {
                    self.finishSuperseded(lookupID: lookupID)
                    return
                }
                guard HTMLDOMSanitizer.bool(raw["found"]) != false else {
                    self.reject(.disconnected)
                    return
                }
                if HTMLDOMSanitizer.bool(raw["truncated"]) == true {
                    self.reject(.payloadTooLarge)
                    return
                }
                let live = try self.sanitize(raw).get()
                let anchor = try HTMLDOMSelectionFreshness.revalidated(
                    snapshot: openedSnapshot,
                    live: live,
                    currentGeneration: self.navigationGeneration,
                    currentSessionId: self.sourceContext?.sessionId ?? "",
                    currentSourceSHA256: self.loadedSourceSHA256,
                    filePath: self.sourceContext?.filePath
                ).get()
                guard self.isPicking,
                      self.activePickSessionID == openedPickSessionID,
                      self.snapshot?.fingerprint == openedSnapshot.fingerprint,
                      let host = self.host,
                      let router = self.router,
                      let source = self.sourceContext else {
                    self.finishSuperseded(lookupID: lookupID)
                    return
                }
                let request = ReviewCommentSelectionRequest(
                    selectedText: live.summaryText,
                    source: source,
                    htmlDOMAnchor: anchor
                )
                self.lastRejection = nil
                self.chrome.setStatus(nil)
                ReviewCommentInlineDraftPresenter.present(
                    sourceView: host,
                    anchorRect: self.highlight.frame,
                    request: request,
                    router: self.routerForSave(
                        expected: openedSnapshot,
                        pickSessionID: openedPickSessionID,
                        router: router
                    )
                )
            } catch let rejection as HTMLDOMSelectionRejection {
                guard self.commentOperationIsCurrent(
                    lookupID: lookupID,
                    generation: openedGeneration,
                    sessionId: openedSessionID,
                    sourceHash: openedSourceHash,
                    pickSessionID: openedPickSessionID
                ) else {
                    self.finishSuperseded(lookupID: lookupID)
                    return
                }
                self.reject(rejection)
            } catch {
                guard self.commentOperationIsCurrent(
                    lookupID: lookupID,
                    generation: openedGeneration,
                    sessionId: openedSessionID,
                    sourceHash: openedSourceHash,
                    pickSessionID: openedPickSessionID
                ) else {
                    self.finishSuperseded(lookupID: lookupID)
                    return
                }
                self.reject(.lookupFailed)
            }
        }
    }

    var lookupClientForTesting: HTMLDOMWebKitLookupClient { client }
    var shieldViewForTesting: UIView { shield }
    var highlightViewForTesting: UIView { highlight }
    var commentButtonForTesting: UIButton { chrome.commentButton }
    var parentButtonForTesting: UIButton { chrome.parentButton }
    var enterButtonForTesting: UIButton { chrome.enterButton }
    var exitButtonForTesting: UIButton { chrome.exitButton }
    var bannerTextForTesting: String? { chrome.bannerLabel.text }
    var statusTextForTesting: String? { chrome.statusLabel.text }
    var selectionLabelForTesting: String? { chrome.selectionLabel.text }
    var snapshotForTesting: HTMLDOMSelectionSnapshot? { snapshot }

    func preparedRequestForTesting() -> ReviewCommentSelectionRequest? {
        guard let sourceContext, let snapshot else { return nil }
        var anchor = snapshot.anchor()
        anchor.filePath = sourceContext.filePath
        return ReviewCommentSelectionRequest(
            selectedText: snapshot.element.summaryText,
            source: sourceContext,
            htmlDOMAnchor: anchor
        )
    }

    private func startLookup(mode: String, point: CGPoint, locator: [HTMLDOMLocatorStep]) {
        guard host?.isRenderReady == true else {
            reject(.notReady)
            return
        }
        let generation = navigationGeneration
        let lookupID = UUID()
        activeLookupID = lookupID
        Task { @MainActor in
            if let hook = beforeLookupResumeForTesting {
                await hook()
            }
            guard self.isCurrent(lookupID, generation: generation) else {
                self.recordStale()
                return
            }
            do {
                let metrics = try await self.currentMetrics()
                guard self.isCurrent(lookupID, generation: generation) else {
                    self.recordStale()
                    return
                }
                let cssPoint = mode == "hit"
                    ? HTMLDOMViewportMapping.cssViewportPoint(fromViewPoint: point, metrics: metrics)
                    : point
                let raw = try await self.client.lookup(mode: mode, cssPoint: cssPoint, locator: locator)
                guard self.isCurrent(lookupID, generation: generation) else {
                    self.recordStale()
                    return
                }
                try self.apply(raw, metrics: metrics)
            } catch let rejection as HTMLDOMSelectionRejection {
                guard self.isCurrent(lookupID, generation: generation) else {
                    self.recordStale()
                    return
                }
                self.reject(rejection)
            } catch {
                guard self.isCurrent(lookupID, generation: generation) else {
                    self.recordStale()
                    return
                }
                self.reject(.lookupFailed)
            }
        }
    }

    private func refreshGeometry(for original: HTMLDOMSelectionSnapshot) {
        let generation = navigationGeneration
        guard let pickSessionID = activePickSessionID else { return }
        let lookupID = UUID()
        activeLookupID = lookupID
        Task { @MainActor in
            do {
                let metrics = try await self.currentMetrics()
                guard self.isCurrent(lookupID, generation: generation),
                      self.activePickSessionID == pickSessionID else {
                    self.recordStale()
                    return
                }
                let raw = try await self.client.lookup(
                    mode: "revalidate",
                    cssPoint: .zero,
                    locator: original.element.locator
                )
                guard self.isCurrent(lookupID, generation: generation),
                      self.activePickSessionID == pickSessionID else {
                    self.recordStale()
                    return
                }
                guard HTMLDOMSanitizer.bool(raw["found"]) != false else {
                    throw HTMLDOMSelectionRejection.disconnected
                }
                if HTMLDOMSanitizer.bool(raw["truncated"]) == true {
                    throw HTMLDOMSelectionRejection.payloadTooLarge
                }
                let live = try self.sanitize(raw).get()
                _ = try HTMLDOMSelectionFreshness.revalidated(
                    snapshot: original,
                    live: live,
                    currentGeneration: self.navigationGeneration,
                    currentSessionId: self.sourceContext?.sessionId ?? "",
                    currentSourceSHA256: self.loadedSourceSHA256,
                    filePath: self.sourceContext?.filePath
                ).get()
                guard self.snapshot?.fingerprint == original.fingerprint else {
                    self.finishSuperseded(lookupID: lookupID)
                    return
                }
                let responseMetrics = metrics.replacingVisual(from: raw)
                let rect = HTMLDOMViewportMapping.viewRect(
                    fromCSSViewportRect: live.cssBounds,
                    metrics: responseMetrics
                )
                self.snapshot?.element = live
                self.highlight.show(rect, label: live.readableLabel)
                self.chrome.updateSelectionLabel(live.readableLabel)
                self.onSelectionGeometryChange?()
                self.lastRejection = nil
                self.completedLookupSerial += 1
                self.host?.bringSubviewToFront(self.highlight)
                self.host?.bringSubviewToFront(self.chrome)
            } catch let rejection as HTMLDOMSelectionRejection {
                guard self.isCurrent(lookupID, generation: generation),
                      self.activePickSessionID == pickSessionID else {
                    self.recordStale()
                    return
                }
                self.reject(rejection)
            } catch {
                guard self.isCurrent(lookupID, generation: generation),
                      self.activePickSessionID == pickSessionID else {
                    self.recordStale()
                    return
                }
                self.reject(.lookupFailed)
            }
        }
    }

    private func apply(_ raw: [String: Any], metrics: HTMLDOMViewportMetrics) throws {
        guard HTMLDOMSanitizer.bool(raw["found"]) != false else {
            throw HTMLDOMSelectionRejection.noElement
        }
        if HTMLDOMSanitizer.bool(raw["truncated"]) == true {
            throw HTMLDOMSelectionRejection.payloadTooLarge
        }
        let element = try sanitize(raw).get()
        guard let sourceContext else { throw HTMLDOMSelectionRejection.sessionMismatch }
        snapshot = HTMLDOMSelectionSnapshot(
            generation: navigationGeneration,
            sessionId: sourceContext.sessionId,
            sourceSHA256: loadedSourceSHA256,
            element: element
        )
        let responseMetrics = metrics.replacingVisual(from: raw)
        let rect = HTMLDOMViewportMapping.viewRect(fromCSSViewportRect: element.cssBounds, metrics: responseMetrics)
        highlight.show(rect, label: element.readableLabel)
        chrome.showSelection(label: element.readableLabel, parentEnabled: element.hasParent)
        onPickStateChange?(true, true)
        chrome.setStatus(limitationStatus(element.limitation))
        lastRejection = nil
        completedLookupSerial += 1
        host?.bringSubviewToFront(highlight)
        host?.bringSubviewToFront(chrome)
    }

    private func sanitize(_ raw: [String: Any]) -> Result<HTMLDOMSanitizedElement, HTMLDOMSelectionRejection> {
        HTMLDOMSanitizer.sanitize(raw)
    }

    private func currentMetrics() async throws -> HTMLDOMViewportMetrics {
        guard let webView else { throw HTMLDOMLookupClientError.missingWebView }
        let visual = try await client.viewport()
        return HTMLDOMViewportMetrics(
            pageZoom: webView.pageZoom > 0 ? webView.pageZoom : 1,
            scrollZoomScale: webView.scrollView.zoomScale > 0 ? webView.scrollView.zoomScale : 1,
            visualViewportScale: visual.scale,
            visualViewportOffset: visual.offset,
            viewportOriginInView: CGPoint(
                x: webView.scrollView.adjustedContentInset.left,
                y: webView.scrollView.adjustedContentInset.top
            ),
            contentOffset: webView.scrollView.contentOffset
        )
    }

    private func isCurrent(_ lookupID: UUID, generation: UInt64) -> Bool {
        isPicking && lookupID == activeLookupID && generation == navigationGeneration
    }

    private func commentOperationIsCurrent(
        lookupID: UUID,
        generation: UInt64,
        sessionId: String,
        sourceHash: String,
        pickSessionID: UUID
    ) -> Bool {
        guard isCurrent(lookupID, generation: generation) else { return false }
        guard activePickSessionID == pickSessionID else { return false }
        guard sourceContext?.sessionId == sessionId else { return false }
        guard loadedSourceSHA256 == sourceHash else { return false }
        return true
    }

    /// A superseded lookup or comment must not clear a newer selection or
    /// restore pick chrome after Browse. Current session and source are read
    /// here, not from values captured before the await.
    private func finishSuperseded(lookupID: UUID) {
        staleLookupCount += 1
        completedLookupSerial += 1
        guard lookupID == activeLookupID, isPicking else { return }
        reject(.staleGeneration)
    }

    private func routerForSave(
        expected: HTMLDOMSelectionSnapshot,
        pickSessionID: UUID,
        router: ReviewCommentSelectionRouter
    ) -> ReviewCommentSelectionRouter {
        ReviewCommentSelectionRouter(
            dispatch: { request in
                router.dispatch(request)
            },
            inlineSave: { [weak self] body, _ in
                guard let self else { return false }
                guard let fresh = await self.requestIfStillFresh(
                    expected: expected,
                    pickSessionID: pickSessionID
                ) else {
                    return false
                }
                return await router.saveInlineComment(body: body, request: fresh)
            },
            inlineQuickComments: router.inlineQuickComments,
            voiceInputManager: router.voiceInputManager,
            stash: router.stash
        )
    }

    private func requestIfStillFresh(
        expected: HTMLDOMSelectionSnapshot,
        pickSessionID: UUID
    ) async -> ReviewCommentSelectionRequest? {
        guard isPicking, activePickSessionID == pickSessionID else {
            noteUnsaved(.staleGeneration, pickSessionID: pickSessionID)
            return nil
        }
        guard expected.generation == navigationGeneration,
              expected.sessionId == sourceContext?.sessionId,
              expected.sourceSHA256 == loadedSourceSHA256 else {
            noteUnsaved(.staleGeneration, pickSessionID: pickSessionID)
            return nil
        }
        do {
            let raw = try await client.lookup(
                mode: "revalidate",
                cssPoint: .zero,
                locator: expected.element.locator
            )
            guard isPicking, activePickSessionID == pickSessionID else {
                noteUnsaved(.staleGeneration, pickSessionID: pickSessionID)
                return nil
            }
            guard expected.generation == navigationGeneration,
                  expected.sessionId == sourceContext?.sessionId,
                  expected.sourceSHA256 == loadedSourceSHA256 else {
                noteUnsaved(.staleGeneration, pickSessionID: pickSessionID)
                return nil
            }
            guard HTMLDOMSanitizer.bool(raw["found"]) != false else {
                noteUnsaved(.disconnected, pickSessionID: pickSessionID)
                return nil
            }
            if HTMLDOMSanitizer.bool(raw["truncated"]) == true {
                noteUnsaved(.payloadTooLarge, pickSessionID: pickSessionID)
                return nil
            }
            let live = try sanitize(raw).get()
            let anchor = try HTMLDOMSelectionFreshness.revalidated(
                snapshot: expected,
                live: live,
                currentGeneration: navigationGeneration,
                currentSessionId: sourceContext?.sessionId ?? "",
                currentSourceSHA256: loadedSourceSHA256,
                filePath: sourceContext?.filePath
            ).get()
            guard isPicking, activePickSessionID == pickSessionID else {
                noteUnsaved(.staleGeneration, pickSessionID: pickSessionID)
                return nil
            }
            guard let source = sourceContext else {
                noteUnsaved(.sessionMismatch, pickSessionID: pickSessionID)
                return nil
            }
            return ReviewCommentSelectionRequest(
                selectedText: live.summaryText,
                source: source,
                htmlDOMAnchor: anchor
            )
        } catch let rejection as HTMLDOMSelectionRejection {
            noteUnsaved(rejection, pickSessionID: pickSessionID)
            return nil
        } catch {
            noteUnsaved(.lookupFailed, pickSessionID: pickSessionID)
            return nil
        }
    }

    private func noteUnsaved(_ rejection: HTMLDOMSelectionRejection, pickSessionID: UUID) {
        if isPicking, activePickSessionID != pickSessionID {
            return
        }
        lastRejection = rejection
        if isPicking, activePickSessionID == pickSessionID {
            chrome.setStatus(rejection.userMessage)
        }
    }

    private func recordStale() {
        staleLookupCount += 1
        lastRejection = .staleGeneration
        completedLookupSerial += 1
    }

    private func reject(_ rejection: HTMLDOMSelectionRejection) {
        lastRejection = rejection
        clearSelection(status: rejection.userMessage)
        completedLookupSerial += 1
    }

    private func clearSelection(status: String?) {
        snapshot = nil
        highlight.hide()
        onSelectionGeometryChange?()
        onPickStateChange?(isPicking, false)
        if isPicking {
            chrome.showPick()
        }
        chrome.clearSelection()
        chrome.setStatus(status)
    }
}

private func limitationStatus(_ limitation: HTMLDOMLookupLimitation?) -> String? {
    switch limitation {
    case .embeddedFrame:
        return "Embedded frame. Inner document is not included."
    case .closedShadowHost:
        return "Closed shadow root or custom element. Inner content was not inspected."
    case nil:
        return nil
    }
}

private extension HTMLDOMViewportMetrics {
    func replacingVisual(from raw: [String: Any]) -> HTMLDOMViewportMetrics {
        let viewport = HTMLDOMSanitizer.dictionary(raw["viewport"]) ?? [:]
        var copy = self
        if let scale = HTMLDOMSanitizer.cgFloat(viewport["scale"]), scale > 0 {
            copy.visualViewportScale = scale
        }
        if let x = HTMLDOMSanitizer.cgFloat(viewport["offsetLeft"]),
           let y = HTMLDOMSanitizer.cgFloat(viewport["offsetTop"]) {
            copy.visualViewportOffset = CGPoint(x: x, y: y)
        }
        return copy
    }
}
