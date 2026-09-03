import UIKit

struct TimelinePreparedRasterImage: @unchecked Sendable {
    let image: UIImage
    let sourcePixelSize: CGSize
    let preparedPixelSize: CGSize
    let decodedByteCost: Int
}

@MainActor
struct TimelineImagePreparationContext {
    let broker: TimelineImagePreparationBroker
    let scope: ChatTimelinePreparationRunway.Scope
    let itemID: String
    let target: ChatTimelinePreparationRunway.ImageTarget
    let loaders: ChatTimelinePreparationRunway.ImageLoaders
    let serverBaseURL: URL?
    let resourcePressure: StreamingRenderPolicy.ResourcePressure
    let onReady: () -> Void
    let onCancelled: () -> Void

    func request(url: URL, visibleDemandID: UUID) -> TimelineImagePreparationBroker.State {
        broker.request(
            url: url,
            scope: scope,
            itemID: itemID,
            target: target,
            loaders: loaders,
            demand: .visible(itemID: itemID, id: visibleDemandID),
            onReady: onReady,
            serverBaseURL: serverBaseURL,
            resourcePressure: resourcePressure
        )
    }

    func preparedImage(for url: URL) -> TimelinePreparedRasterImage? {
        broker.preparedImage(url: url, scope: scope, target: target)
    }

    func cancel(url: URL, visibleDemandID: UUID) {
        broker.cancel(
            url: url,
            scope: scope,
            target: target,
            demand: .visible(itemID: itemID, id: visibleDemandID)
        )
        onCancelled()
    }
}

/// Bounded, identity-keyed preparation for work UIKit is likely to display next.
///
/// Prefetch is deliberately optional: cell configuration still owns the canonical
/// render path when an artifact is absent. The runway only admits finalized
/// assistant markdown and Oppi-owned raster images discovered by that parse.
@MainActor
final class ChatTimelinePreparationRunway {
    typealias Parse = @Sendable (
        _ content: String,
        _ themeID: ThemeID,
        _ scope: Scope,
        _ serverBaseURL: URL?
    ) async -> [MarkdownBlock]?

    struct Scope: Hashable, Sendable {
        let sessionID: String
        let serverID: String?
        let workspaceID: String?
        let worktreeID: String?
    }

    struct ImageTarget: Hashable, Sendable {
        let pointWidth: CGFloat
        let displayScale: CGFloat
        let screenHeight: CGFloat
        let detailScale: CGFloat

        init(
            pointWidth: CGFloat,
            displayScale: CGFloat,
            screenHeight: CGFloat,
            detailScale: CGFloat = 1
        ) {
            self.pointWidth = pointWidth
            self.displayScale = displayScale
            self.screenHeight = screenHeight
            let finite = detailScale.isFinite ? detailScale : 1
            self.detailScale = min(1, max(0.01, finite))
        }

        var widthPixelBucket: Int {
            Self.bucket(pointWidth * displayScale * detailScale)
        }

        var maximumHeightPixelBucket: Int {
            let maximumHeight = ImageViewportSizing.policy(
                for: .inlineProse,
                screenHeight: screenHeight
            ).maximumHeight ?? screenHeight
            return Self.bucket(maximumHeight * displayScale * detailScale)
        }

        private static func bucket(_ value: CGFloat) -> Int {
            let finite = value.isFinite ? value : 1
            return max(64, Int(ceil(max(1, finite) / 64)) * 64)
        }
    }

    struct ImageLoaders {
        let fetchWorkspaceFile: NativeMarkdownImageView.FetchWorkspaceFile?
        let fetchSessionFile: NativeMarkdownImageView.FetchSessionFile?
        let fetchHostFile: NativeMarkdownImageView.FetchHostFile?

        init(
            fetchWorkspaceFile: NativeMarkdownImageView.FetchWorkspaceFile? = nil,
            fetchSessionFile: NativeMarkdownImageView.FetchSessionFile? = nil,
            fetchHostFile: NativeMarkdownImageView.FetchHostFile? = nil
        ) {
            self.fetchWorkspaceFile = fetchWorkspaceFile
            self.fetchSessionFile = fetchSessionFile
            self.fetchHostFile = fetchHostFile
        }
    }

    struct Request {
        let scope: Scope
        let itemID: String
        let content: String
        let isStreaming: Bool
        let themeID: ThemeID
        let serverBaseURL: URL?
        let target: ImageTarget
        let imageLoaders: ImageLoaders

        init(
            scope: Scope,
            itemID: String,
            content: String,
            isStreaming: Bool,
            themeID: ThemeID,
            serverBaseURL: URL?,
            target: ImageTarget,
            imageLoaders: ImageLoaders = ImageLoaders()
        ) {
            self.scope = scope
            self.itemID = itemID
            self.content = content
            self.isStreaming = isStreaming
            self.themeID = themeID
            self.serverBaseURL = serverBaseURL
            self.target = target
            self.imageLoaders = imageLoaders
        }
    }

    enum Demand: Hashable, Sendable {
        case prefetch
        case visible
    }

    enum State: Equatable, Sendable {
        case ready
        case inFlight
        case neverRequested
    }

    private struct Key: Hashable, Sendable {
        let scope: Scope
        let itemID: String
        let contentRevision: UInt64
        let themeID: ThemeID
        let serverBaseURL: URL?
        let widthPixelBucket: Int
        let maximumHeightPixelBucket: Int
    }

    private struct ReadyEntry {
        let blocks: [MarkdownBlock]
        let sourceBytes: Int
        var order: UInt64
    }

    private struct Operation {
        let task: Task<[MarkdownBlock]?, Never>
        let sourceBytes: Int
        let target: ImageTarget
        let imageLoaders: ImageLoaders
        var demands: Set<Demand>
    }

    static let maximumIDsPerPrefetchCallback = 8
    static let maximumParseOperations = 8
    private static let maximumReadyEntries = 16
    private static let maximumReadySourceBytes = 512 * 1_024
    private static let maximumSourceBytesPerRequest = 128 * 1_024

    private var operations: [Key: Operation] = [:]
    private var ready: [Key: ReadyEntry] = [:]
    private var currentKeyByItemID: [String: Key] = [:]
    private var presentationRevisionByItemID: [String: UInt64] = [:]
    private var readySourceBytes = 0
    private var order: UInt64 = 0
    private let imageBroker: TimelineImagePreparationBroker
    private let parse: Parse
    var resourcePressure: StreamingRenderPolicy.ResourcePressure = .nominal {
        didSet {
            guard oldValue != resourcePressure else { return }
            if !StreamingRenderPolicy.admitsSpeculativeRunwayWork(for: resourcePressure) {
                cancelAllPrefetch()
            }
        }
    }
    #if DEBUG
    private(set) var debugPrefetchRequestedItemIDs = Set<String>()
    private(set) var debugCancelAllPrefetchCount = 0
    var debugOperationCount: Int { operations.count }
    var debugTrackedIdentityCount: Int { currentKeyByItemID.count }
    #endif

    var onArtifactReady: ((_ scope: Scope, _ itemID: String, _ presentationRevision: UInt64) -> Void)?

    init(
        imageBroker: TimelineImagePreparationBroker = TimelineImagePreparationBroker(),
        parse: @escaping Parse = { content, _, scope, _ in
            guard !Task.isCancelled else { return nil }
            let blocks = parseCommonMark(content)
            guard !Task.isCancelled else { return nil }
            return MarkdownWikiLinkRewriter.rewrite(
                blocks: blocks,
                serverID: scope.serverID,
                workspaceID: scope.workspaceID,
                sessionID: scope.sessionID,
                sourceDirectory: nil
            )
        }
    ) {
        self.imageBroker = imageBroker
        self.parse = parse
    }

    func request(_ request: Request, demand: Demand) -> State {
        if demand == .prefetch,
           !StreamingRenderPolicy.admitsSpeculativeRunwayWork(for: resourcePressure) {
            cancel(itemID: request.itemID, demand: .prefetch)
            return .neverRequested
        }

        guard !request.isStreaming,
              !request.content.isEmpty,
              request.content.utf8.count <= Self.maximumSourceBytesPerRequest else {
            cancel(itemID: request.itemID, demand: demand)
            return .neverRequested
        }

        let key = key(for: request)

        if var entry = ready[key] {
            replaceCurrentKeyIfNeeded(with: key)
            order &+= 1
            entry.order = order
            ready[key] = entry
            return .ready
        }

        if var operation = operations[key] {
            guard !operation.demands.isEmpty, !operation.task.isCancelled else {
                return .neverRequested
            }
            replaceCurrentKeyIfNeeded(with: key)
            operation.demands.insert(demand)
            operations[key] = operation
            return .inFlight
        }

        // A never-prefetched visible cell uses the canonical synchronous
        // renderer. Starting another parse here would duplicate that work.
        // Still track identity so visible image consumers can join the serial
        // raster broker, including reduced-detail work under serious pressure.
        guard demand == .prefetch else {
            replaceCurrentKeyIfNeeded(with: key)
            return .neverRequested
        }

        replaceCurrentKeyIfNeeded(with: key)
        guard operations.count < Self.maximumParseOperations else {
            if currentKeyByItemID[request.itemID] == key {
                currentKeyByItemID.removeValue(forKey: request.itemID)
                presentationRevisionByItemID.removeValue(forKey: request.itemID)
            }
            return .neverRequested
        }
        #if DEBUG
        debugPrefetchRequestedItemIDs.insert(request.itemID)
        #endif

        let content = request.content
        let themeID = request.themeID
        let scope = request.scope
        let serverBaseURL = request.serverBaseURL
        let parse = parse
        let task = Task.detached(priority: .utility) { () -> [MarkdownBlock]? in
            guard !Task.isCancelled else { return nil }
            let blocks = await parse(content, themeID, scope, serverBaseURL)
            return Task.isCancelled ? nil : blocks
        }
        operations[key] = Operation(
            task: task,
            sourceBytes: content.utf8.count,
            target: request.target,
            imageLoaders: request.imageLoaders,
            demands: [demand]
        )

        Task { [weak self] in
            let blocks = await task.value
            self?.complete(key: key, blocks: blocks)
        }
        return .inFlight
    }

    func state(for request: Request) -> State {
        guard !request.isStreaming else { return .neverRequested }
        let key = key(for: request)
        if ready[key] != nil { return .ready }
        if let operation = operations[key], !operation.demands.isEmpty {
            return .inFlight
        }
        return .neverRequested
    }

    func preparedBlocks(for request: Request) -> [MarkdownBlock]? {
        let key = key(for: request)
        guard var entry = ready[key] else { return nil }
        order &+= 1
        entry.order = order
        ready[key] = entry
        return entry.blocks
    }

    func presentationRevision(for request: Request) -> UInt64 {
        let key = key(for: request)
        guard currentKeyByItemID[request.itemID] == key else { return 0 }
        return presentationRevisionByItemID[request.itemID] ?? 0
    }

    func imagePreparationContext(for request: Request) -> TimelineImagePreparationContext? {
        guard !request.isStreaming else { return nil }
        let key = key(for: request)
        guard currentKeyByItemID[request.itemID] == key else { return nil }
        return TimelineImagePreparationContext(
            broker: imageBroker,
            scope: request.scope,
            itemID: request.itemID,
            target: request.target,
            loaders: request.imageLoaders,
            serverBaseURL: request.serverBaseURL,
            resourcePressure: resourcePressure,
            onReady: { [weak self] in
                self?.handleImagePreparationCompletion(key: key)
            },
            onCancelled: { [weak self] in
                self?.pruneIdentityIfUnused(key)
            }
        )
    }

    func cancel(itemID: String, demand: Demand) {
        let key = currentKeyByItemID[itemID]
        if let key, var operation = operations[key] {
            operation.demands.remove(demand)
            if operation.demands.isEmpty {
                operation.task.cancel()
            }
            operations[key] = operation
        }
        imageBroker.cancel(itemID: itemID, demand: demand)
        if let key { pruneIdentityIfUnused(key) }
    }

    func cancelPrefetch(for itemIDs: some Sequence<String>) {
        for itemID in itemIDs {
            cancel(itemID: itemID, demand: .prefetch)
        }
    }

    func cancelAllPrefetch() {
        #if DEBUG
        debugCancelAllPrefetchCount += 1
        #endif
        for itemID in Array(currentKeyByItemID.keys) {
            cancel(itemID: itemID, demand: .prefetch)
        }
    }

    func cancelAll() {
        for key in Array(operations.keys) {
            guard var operation = operations[key] else { continue }
            operation.demands.removeAll()
            operation.task.cancel()
            operations[key] = operation
        }
        currentKeyByItemID.removeAll(keepingCapacity: false)
        presentationRevisionByItemID.removeAll(keepingCapacity: false)
        imageBroker.cancelAll()
        #if DEBUG
        debugPrefetchRequestedItemIDs.removeAll()
        #endif
    }

    func remove(itemIDs: some Sequence<String>) {
        for itemID in itemIDs {
            if let key = currentKeyByItemID.removeValue(forKey: itemID) {
                presentationRevisionByItemID.removeValue(forKey: itemID)
                if var operation = operations[key] {
                    operation.demands.removeAll()
                    operation.task.cancel()
                    operations[key] = operation
                }
                if let entry = ready.removeValue(forKey: key) {
                    readySourceBytes -= entry.sourceBytes
                }
            }
            imageBroker.cancel(itemID: itemID)
        }
    }

    func trimUnreferencedArtifacts() {
        let trackedKeys = Array(currentKeyByItemID.values)
        ready.removeAll(keepingCapacity: false)
        readySourceBytes = 0
        imageBroker.trimUnreferencedArtifacts()
        for key in trackedKeys {
            pruneIdentityIfUnused(key)
        }
    }

    private func complete(key: Key, blocks: [MarkdownBlock]?) {
        guard let operation = operations.removeValue(forKey: key) else { return }
        guard !operation.task.isCancelled,
              !operation.demands.isEmpty,
              currentKeyByItemID[key.itemID] == key,
              let blocks else {
            pruneIdentityIfUnused(key)
            return
        }

        order &+= 1
        let sourceBytes = operation.sourceBytes
        ready[key] = ReadyEntry(blocks: blocks, sourceBytes: sourceBytes, order: order)
        readySourceBytes += sourceBytes
        evictReadyIfNeeded()
        if operation.demands.contains(.prefetch) {
            prefetchInternalRasterImages(
                in: blocks,
                key: key,
                target: operation.target,
                requestLoaders: operation.imageLoaders
            )
        }
        publishArtifactReadyIfCurrent(key: key)
    }

    private func publishArtifactReadyIfCurrent(key: Key) {
        guard currentKeyByItemID[key.itemID] == key else { return }
        let revision = (presentationRevisionByItemID[key.itemID] ?? 0) &+ 1
        presentationRevisionByItemID[key.itemID] = revision
        onArtifactReady?(key.scope, key.itemID, revision)
    }

    private func prefetchInternalRasterImages(
        in blocks: [MarkdownBlock],
        key: Key,
        target: ImageTarget,
        requestLoaders: ImageLoaders
    ) {
        let urls = Self.imageURLs(in: blocks, key: key)
        var seen = Set<URL>()
        for url in urls where seen.insert(url).inserted && seen.count <= 2 {
            imageBroker.request(
                url: url,
                scope: key.scope,
                itemID: key.itemID,
                target: target,
                loaders: requestLoaders,
                demand: .prefetch(itemID: key.itemID),
                onReady: { [weak self] in
                    self?.handleImagePreparationCompletion(key: key)
                },
                serverBaseURL: key.serverBaseURL,
                resourcePressure: resourcePressure
            )
        }
    }

    private static func imageURLs(in blocks: [MarkdownBlock], key: Key) -> [URL] {
        // FlatSegment promotes only top-level paragraph images to native image
        // views. Matching that boundary avoids fetching images that will remain
        // fallback text inside headings, lists, quotes, or tables.
        let sources = blocks.flatMap { block -> [String] in
            guard case .paragraph(let inlines) = block else { return [] }
            return inlines.compactMap { inline in
                guard case .image(_, let source) = inline else { return nil }
                return source
            }
        }
        return sources.compactMap { source in
            guard let url = FlatSegment.resolveImageURL(
                source: source,
                serverID: key.scope.serverID,
                workspaceID: key.scope.workspaceID,
                sessionID: key.scope.sessionID,
                serverBaseURL: key.serverBaseURL,
                worktreeId: key.scope.worktreeID
            ), RemoteMarkdownImagePolicy.decision(for: url) == .internalImageURL,
               Self.isPrefetchableOwnedRasterURL(
                   url,
                   scope: key.scope,
                   serverBaseURL: key.serverBaseURL
               ) else {
                return nil
            }
            return url
        }
    }

    private func handleImagePreparationCompletion(key: Key) {
        publishArtifactReadyIfCurrent(key: key)
        pruneIdentityIfUnused(key)
    }

    private func replaceCurrentKeyIfNeeded(with key: Key) {
        guard let oldKey = currentKeyByItemID.updateValue(key, forKey: key.itemID),
              oldKey != key else { return }
        presentationRevisionByItemID[key.itemID] = 0
        if var operation = operations[oldKey] {
            operation.demands.removeAll()
            operation.task.cancel()
            operations[oldKey] = operation
        }
        if let entry = ready.removeValue(forKey: oldKey) {
            readySourceBytes -= entry.sourceBytes
        }
    }

    private func evictReadyIfNeeded() {
        guard ready.count > Self.maximumReadyEntries
            || readySourceBytes > Self.maximumReadySourceBytes else { return }
        for (key, entry) in ready.sorted(by: { $0.value.order < $1.value.order }) {
            guard ready.count > Self.maximumReadyEntries
                || readySourceBytes > Self.maximumReadySourceBytes else { break }
            ready.removeValue(forKey: key)
            readySourceBytes -= entry.sourceBytes
            pruneIdentityIfUnused(key)
        }
    }

    private func pruneIdentityIfUnused(_ key: Key) {
        guard ready[key] == nil,
              operations[key] == nil,
              !imageBroker.hasDemand(itemID: key.itemID),
              currentKeyByItemID[key.itemID] == key else { return }
        currentKeyByItemID.removeValue(forKey: key.itemID)
        presentationRevisionByItemID.removeValue(forKey: key.itemID)
    }

    static func isPrefetchableOwnedRasterURL(
        _ url: URL,
        scope: Scope,
        serverBaseURL: URL?
    ) -> Bool {
        if SessionFileURL.parse(url) != nil { return true }
        if HostFileURL.parse(url) != nil { return true }
        guard let workspace = WorkspaceFileURL.parse(url),
              workspace.workspaceID == scope.workspaceID,
              let serverBaseURL else {
            return false
        }
        return matchesTrustedServerBase(url, serverBaseURL: serverBaseURL)
    }

    private static func matchesTrustedServerBase(_ url: URL, serverBaseURL: URL) -> Bool {
        guard let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let baseComponents = URLComponents(url: serverBaseURL, resolvingAgainstBaseURL: false) else {
            return false
        }
        let urlScheme = urlComponents.scheme?.lowercased()
        let baseScheme = baseComponents.scheme?.lowercased()
        guard let urlScheme, urlScheme == baseScheme else { return false }
        guard let urlHost = urlComponents.host?.lowercased(),
              let baseHost = baseComponents.host?.lowercased(),
              urlHost == baseHost else {
            return false
        }
        let urlPort = urlComponents.port ?? defaultPort(for: urlScheme)
        let basePort = baseComponents.port ?? defaultPort(for: baseScheme)
        guard urlPort == basePort else { return false }

        let urlPath = urlComponents.path.isEmpty ? "/" : urlComponents.path
        let basePath = normalizedBasePath(baseComponents.path)
        if basePath.isEmpty {
            return urlPath.hasPrefix("/workspaces/") || urlPath.hasPrefix("/files/")
        }
        return urlPath.hasPrefix(basePath + "/workspaces/")
            || urlPath.hasPrefix(basePath + "/files/")
    }

    private static func defaultPort(for scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    private static func normalizedBasePath(_ path: String) -> String {
        if path.isEmpty || path == "/" { return "" }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private func key(for request: Request) -> Key {
        Key(
            scope: request.scope,
            itemID: request.itemID,
            contentRevision: Self.stableRevision(request.content),
            themeID: request.themeID,
            serverBaseURL: request.serverBaseURL,
            widthPixelBucket: request.target.widthPixelBucket,
            maximumHeightPixelBucket: request.target.maximumHeightPixelBucket
        )
    }

    static func stableRevision(_ content: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}


@MainActor
final class TimelineImagePreparationBroker {
    enum State: Equatable, Sendable {
        case ready
        case inFlight
        case neverRequested
    }

    enum Demand: Hashable, Sendable {
        case prefetch(itemID: String)
        case visible(itemID: String, id: UUID)

        var itemID: String {
            switch self {
            case .prefetch(let itemID), .visible(let itemID, _): itemID
            }
        }

        var isVisible: Bool {
            if case .visible = self { return true }
            return false
        }
    }

    private struct Key: Hashable, Sendable {
        let scope: ChatTimelinePreparationRunway.Scope
        let url: URL
        let widthPixelBucket: Int
        let maximumHeightPixelBucket: Int
    }

    private struct CachedEntry {
        let artifact: TimelinePreparedRasterImage
        var order: UInt64
    }

    private final class Operation {
        let id = UUID()
        let key: Key
        let target: ChatTimelinePreparationRunway.ImageTarget
        let loaders: ChatTimelinePreparationRunway.ImageLoaders
        var demands: Set<Demand>
        var callbacksByItemID: [String: () -> Void]
        var task: Task<TimelinePreparedRasterImage?, Never>?

        init(
            key: Key,
            target: ChatTimelinePreparationRunway.ImageTarget,
            loaders: ChatTimelinePreparationRunway.ImageLoaders,
            demand: Demand,
            callback: @escaping () -> Void
        ) {
            self.key = key
            self.target = target
            self.loaders = loaders
            demands = [demand]
            callbacksByItemID = [demand.itemID: callback]
        }
    }

    private enum PreparationError: Error {
        case unavailable
    }

    private static let maximumConcurrentFetches = 3
    static let maximumOperations = 16
    static let maximumDemandRegistrations = 32
    private static let maximumDemandsPerItemPerOperation = 3
    private static let maximumImagesPerItem = 2
    private static let maximumDecodedCost = 48 * 1_024 * 1_024
    private static let maximumCacheEntries = 24

    private let rasterPreparer: TimelineSerialRasterPreparer
    private var operations: [Key: Operation] = [:]
    private var queuedKeys: [Key] = []
    private var cache: [Key: CachedEntry] = [:]
    private var failedKeys: [Key: UInt64] = [:]
    private var admittedKeysByItemID: [String: Set<Key>] = [:]
    private var decodedCost = 0
    private var activeFetchCount = 0
    private var order: UInt64 = 0

    init(rasterPreparer: TimelineSerialRasterPreparer = TimelineSerialRasterPreparer()) {
        self.rasterPreparer = rasterPreparer
    }

    @discardableResult
    func request(
        url: URL,
        scope: ChatTimelinePreparationRunway.Scope,
        itemID: String,
        target: ChatTimelinePreparationRunway.ImageTarget,
        loaders: ChatTimelinePreparationRunway.ImageLoaders,
        demand: Demand,
        onReady: @escaping () -> Void,
        serverBaseURL: URL? = nil,
        resourcePressure: StreamingRenderPolicy.ResourcePressure = .nominal
    ) -> State {
        guard demand.itemID == itemID,
              RemoteMarkdownImagePolicy.decision(for: url) == .internalImageURL,
              ChatTimelinePreparationRunway.isPrefetchableOwnedRasterURL(
                  url,
                  scope: scope,
                  serverBaseURL: serverBaseURL
              ),
              Self.hasInternalLoader(for: url, loaders: loaders) else {
            return .neverRequested
        }

        let key = makeKey(url: url, scope: scope, target: target)
        if var cached = cache[key] {
            order &+= 1
            cached.order = order
            cache[key] = cached
            return .ready
        }

        if let operation = operations[key] {
            guard !operation.demands.isEmpty else { return .neverRequested }
            if operation.demands.contains(demand) {
                operation.callbacksByItemID[itemID] = onReady
                return .inFlight
            }
            let itemDemandCount = operation.demands.lazy.filter { $0.itemID == itemID }.count
            guard demandRegistrationCount < Self.maximumDemandRegistrations,
                  itemDemandCount < Self.maximumDemandsPerItemPerOperation else {
                return .neverRequested
            }
            if case .visible = demand {
                let itemAlreadyOnOperation =
                    itemDemandCount > 0 || admittedKeysByItemID[itemID]?.contains(key) == true
                guard itemAlreadyOnOperation else { return .neverRequested }
            }
            if case .prefetch = demand,
               admittedKeysByItemID[itemID]?.contains(key) != true {
                guard admittedKeysByItemID[itemID, default: []].count < Self.maximumImagesPerItem else {
                    return .neverRequested
                }
                admittedKeysByItemID[itemID, default: []].insert(key)
            }
            operation.demands.insert(demand)
            operation.callbacksByItemID[itemID] = onReady
            pump()
            return .inFlight
        }
        if failedKeys[key] != nil {
            return .neverRequested
        }
        let mayStart: Bool
        switch demand {
        case .prefetch:
            mayStart = StreamingRenderPolicy.admitsSpeculativeRunwayWork(for: resourcePressure)
        case .visible:
            // Nominal visible misses stay on the canonical renderer. Serious
            // visible work starts here so destination-size decode stays serial
            // and reduced.
            mayStart = StreamingRenderPolicy.decision(
                for: .rasterImage,
                pressure: resourcePressure,
                consumer: .visible
            ) == .reducedDetail
        }
        guard mayStart,
              admittedKeysByItemID[itemID, default: []].count < Self.maximumImagesPerItem,
              operations.count < Self.maximumOperations,
              demandRegistrationCount < Self.maximumDemandRegistrations else {
            return .neverRequested
        }

        admittedKeysByItemID[itemID, default: []].insert(key)
        let operation = Operation(
            key: key,
            target: target,
            loaders: loaders,
            demand: demand,
            callback: onReady
        )
        operations[key] = operation
        queuedKeys.append(key)
        pump()
        return .inFlight
    }

    func preparedImage(
        url: URL,
        scope: ChatTimelinePreparationRunway.Scope,
        target: ChatTimelinePreparationRunway.ImageTarget
    ) -> TimelinePreparedRasterImage? {
        let key = makeKey(url: url, scope: scope, target: target)
        guard var cached = cache[key] else { return nil }
        order &+= 1
        cached.order = order
        cache[key] = cached
        return cached.artifact
    }

    func cancel(
        url: URL,
        scope: ChatTimelinePreparationRunway.Scope,
        target: ChatTimelinePreparationRunway.ImageTarget,
        demand: Demand
    ) {
        let key = makeKey(url: url, scope: scope, target: target)
        remove(demand: demand, from: key)
    }

    func cancel(itemID: String, demand: ChatTimelinePreparationRunway.Demand? = nil) {
        let matching: [(Key, Demand)] = operations.flatMap { key, operation in
            operation.demands.compactMap { token in
                guard token.itemID == itemID else { return nil }
                let matchesKind: Bool
                switch (demand, token) {
                case (.prefetch?, .prefetch): matchesKind = true
                case (.visible?, .visible): matchesKind = true
                case (nil, _): matchesKind = true
                default: matchesKind = false
                }
                return matchesKind ? (key, token) : nil
            }
        }
        for (key, token) in matching {
            remove(demand: token, from: key)
        }
    }

    func cancelAll() {
        for key in Array(operations.keys) {
            guard let operation = operations[key] else { continue }
            operation.demands.removeAll()
            operation.callbacksByItemID.removeAll()
            if operation.task == nil {
                operations.removeValue(forKey: key)
                releaseAdmission(for: key)
            } else {
                operation.task?.cancel()
            }
        }
        queuedKeys.removeAll(keepingCapacity: false)
    }

    func trimUnreferencedArtifacts() {
        cache.removeAll(keepingCapacity: false)
        failedKeys.removeAll(keepingCapacity: false)
        decodedCost = 0
    }

    #if DEBUG
    var debugDecodedCostForTesting: Int { decodedCost }
    var debugInFlightCountForTesting: Int { operations.count }
    var debugTrackedAdmissionCountForTesting: Int {
        admittedKeysByItemID.values.reduce(0) { $0 + $1.count }
    }
    var debugDemandRegistrationCountForTesting: Int { demandRegistrationCount }
    var debugMaximumConcurrentRasterPreparationsForTesting: Int {
        get async { await rasterPreparer.maximumObservedConcurrency }
    }
    #endif

    private func remove(demand: Demand, from key: Key) {
        guard let operation = operations[key] else { return }
        operation.demands.remove(demand)
        if !operation.demands.contains(where: { $0.itemID == demand.itemID }) {
            operation.callbacksByItemID.removeValue(forKey: demand.itemID)
            if !operation.demands.isEmpty {
                releaseAdmission(itemID: demand.itemID, key: key)
            }
        }
        guard operation.demands.isEmpty else { return }

        if operation.task == nil {
            operations.removeValue(forKey: key)
            queuedKeys.removeAll { $0 == key }
            releaseAdmission(for: key)
            pump()
        } else {
            // A loader may ignore cooperative cancellation. Keep the active
            // tombstone and its slot until task completion so physical fetch
            // concurrency never exceeds the configured bound.
            operation.task?.cancel()
        }
    }

    private func pump() {
        while activeFetchCount < Self.maximumConcurrentFetches {
            let nextIndex = queuedKeys.firstIndex { key in
                operations[key]?.demands.contains(where: \.isVisible) == true
            } ?? queuedKeys.indices.first
            guard let nextIndex else { return }
            let key = queuedKeys.remove(at: nextIndex)
            guard let operation = operations[key], operation.task == nil else { continue }
            start(operation)
        }
    }

    private func start(_ operation: Operation) {
        activeFetchCount += 1
        let operationID = operation.id
        let url = operation.key.url
        let target = operation.target
        let loaders = operation.loaders
        let rasterPreparer = rasterPreparer
        let task = Task { @MainActor () -> TimelinePreparedRasterImage? in
            do {
                guard !Task.isCancelled else { return nil }
                let fetched = try await Self.fetchInternalImage(
                    url: url,
                    loaders: loaders
                )
                guard !Task.isCancelled else { return nil }
                return await rasterPreparer.prepare(
                    data: fetched.data,
                    filePath: fetched.filePath,
                    target: target
                )
            } catch {
                return nil
            }
        }
        operation.task = task
        Task { [weak self] in
            let artifact = await task.value
            self?.finish(key: operation.key, operationID: operationID, artifact: artifact)
        }
    }

    private func finish(
        key: Key,
        operationID: UUID,
        artifact: TimelinePreparedRasterImage?
    ) {
        guard let operation = operations[key], operation.id == operationID else { return }
        operations.removeValue(forKey: key)
        releaseAdmission(for: key)
        activeFetchCount = max(0, activeFetchCount - 1)

        let callbacks = operation.callbacksByItemID.values
        if !operation.demands.isEmpty {
            if let artifact {
                insert(artifact, for: key)
            } else {
                recordFailure(for: key)
            }
            for callback in callbacks { callback() }
        }
        pump()
    }

    private var demandRegistrationCount: Int {
        operations.values.reduce(0) { $0 + $1.demands.count }
    }

    private func releaseAdmission(for key: Key) {
        for itemID in Array(admittedKeysByItemID.keys) {
            releaseAdmission(itemID: itemID, key: key)
        }
    }

    private func releaseAdmission(itemID: String, key: Key) {
        admittedKeysByItemID[itemID]?.remove(key)
        if admittedKeysByItemID[itemID]?.isEmpty == true {
            admittedKeysByItemID.removeValue(forKey: itemID)
        }
    }

    func hasDemand(itemID: String) -> Bool {
        operations.values.contains { operation in
            operation.demands.contains { $0.itemID == itemID }
        }
    }

    private func recordFailure(for key: Key) {
        order &+= 1
        failedKeys[key] = order
        if failedKeys.count > Self.maximumCacheEntries,
           let oldest = failedKeys.min(by: { $0.value < $1.value })?.key {
            failedKeys.removeValue(forKey: oldest)
        }
    }

    private func insert(_ artifact: TimelinePreparedRasterImage, for key: Key) {
        guard artifact.decodedByteCost <= Self.maximumDecodedCost else { return }
        if let existing = cache[key] {
            decodedCost -= existing.artifact.decodedByteCost
        }
        order &+= 1
        cache[key] = CachedEntry(artifact: artifact, order: order)
        decodedCost += artifact.decodedByteCost

        guard cache.count > Self.maximumCacheEntries
            || decodedCost > Self.maximumDecodedCost else { return }
        for (oldKey, entry) in cache.sorted(by: { $0.value.order < $1.value.order }) {
            guard cache.count > Self.maximumCacheEntries
                || decodedCost > Self.maximumDecodedCost else { break }
            cache.removeValue(forKey: oldKey)
            decodedCost -= entry.artifact.decodedByteCost
        }
    }

    private func makeKey(
        url: URL,
        scope: ChatTimelinePreparationRunway.Scope,
        target: ChatTimelinePreparationRunway.ImageTarget
    ) -> Key {
        Key(
            scope: scope,
            url: url,
            widthPixelBucket: target.widthPixelBucket,
            maximumHeightPixelBucket: target.maximumHeightPixelBucket
        )
    }

    private static func hasInternalLoader(
        for url: URL,
        loaders: ChatTimelinePreparationRunway.ImageLoaders
    ) -> Bool {
        if SessionFileURL.parse(url) != nil { return loaders.fetchSessionFile != nil }
        if WorkspaceFileURL.parse(url) != nil { return loaders.fetchWorkspaceFile != nil }
        if HostFileURL.parse(url) != nil { return loaders.fetchHostFile != nil }
        return false
    }

    private static func fetchInternalImage(
        url: URL,
        loaders: ChatTimelinePreparationRunway.ImageLoaders
    ) async throws -> (data: Data, filePath: String) {
        if let components = SessionFileURL.parse(url), let fetch = loaders.fetchSessionFile {
            return (
                try await fetch(components.workspaceID, components.sessionID, components.filePath),
                components.filePath
            )
        }
        if let components = WorkspaceFileURL.parse(url), let fetch = loaders.fetchWorkspaceFile {
            return (
                try await fetch(components.workspaceID, components.filePath),
                components.filePath
            )
        }
        if let path = HostFileURL.parse(url), let fetch = loaders.fetchHostFile {
            return (try await fetch(path), path)
        }
        throw PreparationError.unavailable
    }
}

actor TimelineSerialRasterPreparer {
    private(set) var maximumObservedConcurrency = 0
    private var activePreparations = 0

    func prepare(
        data: Data,
        filePath: String,
        target: ChatTimelinePreparationRunway.ImageTarget
    ) -> TimelinePreparedRasterImage? {
        activePreparations += 1
        maximumObservedConcurrency = max(maximumObservedConcurrency, activePreparations)
        defer { activePreparations -= 1 }
        guard !Task.isCancelled else { return nil }

        let pathMimeType = MediaMimeType.imageMimeType(
            forPathExtension: (filePath as NSString).pathExtension
        )
        let inspection = ImageMediaInspector.inspect(data: data, mimeType: pathMimeType)
        guard !inspection.prefersWebRenderer,
              let sourcePixelSize = inspection.pixelSize,
              ImageViewportSizing.validatedHeightToWidthRatio(
                  width: sourcePixelSize.width,
                  height: sourcePixelSize.height
              ) != nil else { return nil }

        let widthLimit = CGFloat(target.widthPixelBucket)
        let heightLimit = CGFloat(target.maximumHeightPixelBucket)
        let destinationScale = min(
            1,
            widthLimit / sourcePixelSize.width,
            heightLimit / sourcePixelSize.height
        )
        let destinationPixelSize = CGSize(
            width: ceil(sourcePixelSize.width * destinationScale),
            height: ceil(sourcePixelSize.height * destinationScale)
        )
        let destinationMaxPixel = max(
            destinationPixelSize.width,
            destinationPixelSize.height
        )
        guard destinationMaxPixel > 0, !Task.isCancelled,
              let sourceImage = UIImage(data: data) else { return nil }

        let prepared: UIImage?
        if destinationScale < 1 {
            prepared = sourceImage.preparingThumbnail(
                of: destinationPixelSize
            ) ?? ImageMediaInspector.downsampledImage(
                data: data,
                maxPixelSize: destinationMaxPixel
            )?.preparingForDisplay()
        } else {
            prepared = sourceImage.preparingForDisplay() ?? sourceImage
        }
        guard !Task.isCancelled, let prepared else { return nil }

        let pixelWidth = prepared.cgImage?.width
            ?? Int((prepared.size.width * prepared.scale).rounded(.up))
        let pixelHeight = prepared.cgImage?.height
            ?? Int((prepared.size.height * prepared.scale).rounded(.up))
        let cost = max(1, pixelWidth) * max(1, pixelHeight) * 4
        return TimelinePreparedRasterImage(
            image: prepared,
            sourcePixelSize: sourcePixelSize,
            preparedPixelSize: CGSize(width: pixelWidth, height: pixelHeight),
            decodedByteCost: cost
        )
    }
}


extension ChatTimelineCollectionHost.Controller: UICollectionViewDataSourcePrefetching {
    func makeTimelinePreparationRequest(
        itemID: String,
        text: String,
        isStreaming: Bool,
        rowConfiguration: AssistantTimelineRowConfiguration
    ) -> ChatTimelinePreparationRunway.Request {
        let target = timelineImageTarget()
        return ChatTimelinePreparationRunway.Request(
            scope: ChatTimelinePreparationRunway.Scope(
                sessionID: sessionId,
                serverID: serverId,
                workspaceID: workspaceId,
                worktreeID: rowConfiguration.worktreeId
            ),
            itemID: itemID,
            content: text,
            isStreaming: isStreaming,
            themeID: ThemeRuntimeState.currentThemeID(),
            serverBaseURL: rowConfiguration.serverBaseURL,
            target: target,
            imageLoaders: ChatTimelinePreparationRunway.ImageLoaders(
                fetchWorkspaceFile: rowConfiguration.fetchWorkspaceFile,
                fetchSessionFile: rowConfiguration.fetchSessionFile,
                fetchHostFile: rowConfiguration.fetchHostFile
            )
        )
    }

    func collectionView(
        _ collectionView: UICollectionView,
        prefetchItemsAt indexPaths: [IndexPath]
    ) {
        let stableIDs = indexPaths.lazy.compactMap { indexPath in
            self.dataSource?.itemIdentifier(for: indexPath)
        }
        let boundedIDs = Array(stableIDs.prefix(
            ChatTimelinePreparationRunway.maximumIDsPerPrefetchCallback
        ))
        guard !boundedIDs.isEmpty else { return }

        let center = boundedIDs.compactMap { self.currentIDs.firstIndex(of: $0) }.reduce(0, +)
            / max(1, boundedIDs.count)
        if let previousCenter = lastPrefetchCenterIndex {
            let nextDirection = center == previousCenter ? lastPrefetchDirection : (center > previousCenter ? 1 : -1)
            if lastPrefetchDirection != 0,
               nextDirection != 0,
               nextDirection != lastPrefetchDirection {
                preparationRunway.cancelAllPrefetch()
            }
            lastPrefetchDirection = nextDirection
        }
        lastPrefetchCenterIndex = center

        guard StreamingRenderPolicy.admitsSpeculativeRunwayWork(for: resourcePressure) else {
            return
        }

        for itemID in boundedIDs {
            guard let item = currentItemByID[itemID],
                  case .assistantMessage = item,
                  let rowConfiguration = assistantBaseRowConfiguration(
                      itemID: itemID,
                      item: item
                  ) else { continue }
            let request = makeTimelinePreparationRequest(
                itemID: itemID,
                text: rowConfiguration.renderedMarkdownSource,
                isStreaming: rowConfiguration.isStreaming,
                rowConfiguration: rowConfiguration
            )
            _ = preparationRunway.request(request, demand: .prefetch)
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        let stableIDs = indexPaths.compactMap { indexPath in
            self.dataSource?.itemIdentifier(for: indexPath)
        }
        preparationRunway.cancelPrefetch(for: stableIDs)
    }

    func cancelTimelinePreparation() {
        preparationRunway.cancelAll()
        preparationRunway.trimUnreferencedArtifacts()
        lastPrefetchCenterIndex = nil
        lastPrefetchDirection = 0
    }

    func applyResourcePressure(_ pressure: StreamingRenderPolicy.ResourcePressure) {
        #if DEBUG
        debugLastResourcePressureAppliedOnMainActorForTesting = Thread.isMainThread
        #endif
        resourcePressure = pressure
        // Entering serious/critical cancels speculative runway work only.
        // Visible/explicit consumers stay; prepared artifacts stay cached.
        // Recovery does not reconfigure the window or drain a backlog.
        preparationRunway.resourcePressure = pressure
    }

    @objc nonisolated func handleResourcePressureDidChange() {
        Task { @MainActor [weak self] in
            self?.applyResourcePressureFromNotification()
        }
    }

    private func applyResourcePressureFromNotification() {
        #if DEBUG
        if let injected = debugNextNotificationPressureForTesting {
            debugNextNotificationPressureForTesting = nil
            applyResourcePressure(injected)
            return
        }
        if debugIgnoresLiveProcessInfoResourcePressureForTesting {
            return
        }
        #endif
        applyResourcePressure(.current())
    }

    #if DEBUG
    func debugInstallResourcePressureSnapshotForTesting(
        _ pressure: StreamingRenderPolicy.ResourcePressure
    ) {
        debugIgnoresLiveProcessInfoResourcePressureForTesting = true
        applyResourcePressure(pressure)
    }
    #endif

    @objc func handleTimelineMemoryWarning() {
        preparationRunway.trimUnreferencedArtifacts()
    }

    func handlePreparedArtifact(
        scope: ChatTimelinePreparationRunway.Scope,
        itemID: String
    ) {
        guard scope.sessionID == sessionId,
              scope.serverID == serverId,
              scope.workspaceID == workspaceId,
              currentItemByID[itemID] != nil,
              let collectionView,
              let indexPath = dataSource?.indexPath(for: itemID),
              collectionView.indexPathsForVisibleItems.contains(indexPath) else {
            return
        }
        #if DEBUG
        debugPreparedArtifactReconfiguredItemIDs.append(itemID)
        #endif
        reconfigureItems([itemID], in: collectionView)
    }

    private func timelineImageTarget() -> ChatTimelinePreparationRunway.ImageTarget {
        let fallbackBounds = UIScreen.main.bounds
        let collectionBounds = collectionView?.bounds ?? fallbackBounds
        let pointWidth = max(
            1,
            collectionBounds.width
                - 32
                - AssistantTimelineRowContentView.bubbleLeadingPadding
                - AssistantTimelineRowContentView.bubbleTrailingPadding
        )
        let screen = collectionView?.window?.windowScene?.screen
        return ChatTimelinePreparationRunway.ImageTarget(
            pointWidth: pointWidth,
            displayScale: screen?.scale ?? UIScreen.main.scale,
            screenHeight: screen?.bounds.height ?? fallbackBounds.height,
            detailScale: StreamingRenderPolicy.imageDetailScale(for: resourcePressure)
        )
    }

    #if DEBUG
    var debugPreparationRunwayForTesting: ChatTimelinePreparationRunway {
        preparationRunway
    }
    #endif
}
