import CoreGraphics
import Foundation
import GhosttyVt

struct SSHTerminalGeometry: Equatable, Sendable {
    var columns = 80
    var rows = 24
    var cellWidth = 8
    var cellHeight = 17
    var pixelWidth: Int { columns * cellWidth }
    var pixelHeight: Int { rows * cellHeight }
}

struct SSHTerminalCell {
    /// 0 when empty or when `cluster` holds a multi-scalar grapheme.
    let scalar: UInt32
    /// Set only for combining / multi-scalar cells. Plain ASCII never allocates.
    let cluster: String?
    let width: Int
    let foreground: GhosttyColorRgb
    let background: GhosttyColorRgb
    let style: GhosttyStyle

    var text: String {
        if let cluster { return cluster }
        guard scalar != 0, let unit = Unicode.Scalar(scalar) else { return "" }
        return String(unit)
    }
}

struct SSHTerminalFrame {
    /// Viewport rows, then `rowsBelowViewport` history rows under them. A
    /// history scroll that stops between rows shifts the grid up by part of a
    /// row and draws those into the gap at the bottom.
    let rows: [[SSHTerminalCell]]
    let rowsBelowViewport: Int
    let cursor: GhosttyRenderStateCursor
    let background: GhosttyColorRgb
    /// Rows rebuilt on this snapshot. Empty when the picture did not change.
    let rebuiltRows: IndexSet
    /// Kitty graphics on this screen. Nil when there is nothing stored, so a
    /// terminal that never shows an image pays nothing for the feature.
    let kitty: SSHTerminalKittySnapshot?

    /// Changes whenever image storage changes, so a repaint can be gated on it
    /// even when no text row moved.
    var kittyGeneration: UInt64 { kitty?.generation ?? 0 }
}

/// Separate from the passive log owner. All C access (including callbacks and
/// borrowed render data) runs synchronously on MainActor. Frames own their text
/// and value structs; no borrowed pointer escapes to UIKit. Paint is coalesced
/// by the surface, never interpretation. Effects start NULL and only the
/// entries below gain authority. Clipboard access is write-only: a remote
/// copy (OSC 52, as Herdr and tmux forward it) of UTF-8 text to the standard
/// clipboard reaches `copied`; there is no read callback, so the host can never
/// see this device's clipboard.
@MainActor
final class SSHTerminalEngine {
    static let maximumPasteBytes = 64 * 1024
    static let maximumCopyBytes = 1024 * 1024
    /// Bytes of decoded Kitty images kept per screen. Enough for a handful of
    /// full-window pictures (`kitten icat`, chafa, Pi image output) while a
    /// remote host cannot exhaust memory: libghostty evicts the oldest images
    /// past this and rejects anything larger. Only the direct transmission
    /// medium is enabled, so this is never backed by a local file.
    static let kittyImageStorageLimit = SSHTerminalKittyGraphics.imageStorageLimitBytes
    /// Receives a remote copy after the triggering write has been interpreted.
    var copied: (String) -> Void = { _ in }
    /// The last copy of the current write; only the newest one matters.
    private var pendingCopy: String?
    private var terminal: GhosttyTerminal?
    private var render: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var cells: GhosttyRenderStateRowCells?
    private var encoder: GhosttyKeyEncoder?
    private var mouseEncoder: GhosttyMouseEncoder?
    private var selectionGesture: GhosttySelectionGesture?
    private var selectionPress: GhosttySelectionGestureEvent?
    private var selectionDrag: GhosttySelectionGestureEvent?
    private var selectionRelease: GhosttySelectionGestureEvent?
    private var replies = [Data]()
    private var live = true
    private var titleChanged = false
    private var pwdChanged = false
    private var heldSince: ContinuousClock.Instant?
    private let sink: (Data) -> Void
    private(set) var title = ""
    /// The shell's working directory as a local path, from OSC 7. Only a
    /// `file:` URL becomes a path: the raw OSC value is whatever bytes the
    /// shell emitted, and a bare path or another scheme leaves this empty so
    /// relative paths stay unopenable rather than guessed.
    private(set) var workingDirectory = ""
    /// The machine the first usable OSC 7 report named on this connection. A
    /// later report from another machine (a nested ssh, a tmux session on a
    /// different host) leaves the folder unknown instead of resolving this
    /// server's paths against it.
    private var workingDirectoryHost: String?
    /// OSC 7501 records for this terminal. Outlives `close()` so unseen
    /// `done`/`error` records can still be shown after the program exits.
    let programStatus = SSHTerminalProgramStatusStore()
    /// OSC 9 / OSC 777 notifications and BEL from this terminal.
    let alerts = SSHTerminalAlertFeed()
    private(set) var geometry: SSHTerminalGeometry
    private(set) var following = true
    /// Bumped by anything that can change the picture. The display link repaints
    /// when it moved, so output never invalidates SwiftUI.
    private(set) var changeCount = 0
    /// Starts the grid display link. Without this, an idle-paused link never
    /// sees PTY output, scroll, or resize.
    var onPictureChange: (() -> Void)?
    var dark = true
    var renderHeld: Bool { heldSince != nil }
    /// Viewport rows from the last `frame()`. Dirty rows replace one entry.
    private var cachedRows: [[SSHTerminalCell]] = []
    private var cachedCursor: GhosttyRenderStateCursor?
    /// `changeCount` the cached rows cover, so text read between paints knows
    /// when it needs a snapshot of its own.
    private var cachedRowsChangeCount = -1
    /// Kitty graphics cache: the snapshot is replaced when its store or the
    /// viewport geometry changed, never re-read per frame otherwise.
    private var kittySnapshot: SSHTerminalKittySnapshot?
    private var kittyStoreGeneration: UInt64 = .max
    private var kittyViewportTop = -1
    private var kittyStoreColumns = 0
    private var kittyStoreRows = 0
    private var kittyStoreCellWidth = 0
    private var kittyStoreCellHeight = 0
    /// Placement reads, for the perf bench and tests: unchanged frames must not
    /// walk the placement list again.
    private(set) var kittyPlacementReadCount = 0
    /// Resize and scroll move every row; rebuild the whole grid.
    private var forceFullRebuild = true

    init(geometry: SSHTerminalGeometry = .init(), sink: @escaping (Data) -> Void) throws {
        self.geometry = geometry
        self.sink = sink
        guard ghostty_terminal_new(nil, &terminal, UInt16(geometry.columns), UInt16(geometry.rows)) == GHOSTTY_SUCCESS,
              ghostty_render_state_new(nil, &render) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_iterator_new(nil, &rowIterator) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS,
              ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS,
              ghostty_mouse_encoder_new(nil, &mouseEncoder) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_new(nil, &selectionGesture) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_new(nil, &selectionPress, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_new(nil, &selectionDrag, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG) == GHOSTTY_SUCCESS,
              ghostty_selection_gesture_event_new(nil, &selectionRelease, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE) == GHOSTTY_SUCCESS else {
            throw SSHTerminalError.engineUnavailable
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        installEffects()
        // Apply the cell pixel size now, not only on the first remote resize:
        // Kitty placement geometry is computed in terminal pixels, so a zero
        // cell size would collapse every image until the first resize.
        ghostty_terminal_resize(terminal, UInt16(geometry.columns), UInt16(geometry.rows),
                                UInt32(geometry.cellWidth), UInt32(geometry.cellHeight))
        var historyLimit: Int = 8 * 1024 * 1024
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &historyLimit)
        // Ghostty default: DEC 1007 on. Set both the live value and the RIS
        // restore so less/man/git-log pagers keep alternate scroll.
        var altScroll = GhosttyTerminalModeConfig(mode: ghostty_mode_new(1007, false), value: true)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &altScroll)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &altScroll)
        // Kitty graphics: PNG decoding through ImageIO, a bounded image store,
        // and only the direct (t=d) medium. The file, temporary-file and
        // shared-memory mediums would let a remote host make this device read
        // local files, so they stay off; libghostty answers such a transmission
        // with `EINVAL: unsupported medium`.
        SSHTerminalKittyPNGDecoder.install()
        var imageStorage = UInt64(Self.kittyImageStorageLimit)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &imageStorage)
        var localMediums = false
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &localMediums)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &localMediums)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, nil)
        // Two rows under the viewport cover a grid shifted up by up to one row
        // plus the part-row strip under the last whole row. libghostty only
        // captures rows that exist, so the live screen reads none.
        var overscan = GhosttyRenderStateOverscan(above: 0, below: 2)
        ghostty_render_state_set(render, GHOSTTY_RENDER_STATE_OPTION_OVERSCAN, &overscan)
    }

    isolated deinit {
        ghostty_selection_gesture_event_free(selectionRelease)
        ghostty_selection_gesture_event_free(selectionDrag)
        ghostty_selection_gesture_event_free(selectionPress)
        ghostty_selection_gesture_free(selectionGesture, terminal)
        ghostty_mouse_encoder_free(mouseEncoder)
        ghostty_key_encoder_free(encoder)
        ghostty_render_state_row_cells_free(cells)
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_free(render)
        ghostty_terminal_free(terminal)
    }

    func close() {
        live = false
        replies.removeAll()
        pendingCopy = nil
        programStatus.processEnded()
    }

    private func notePictureChange() {
        changeCount &+= 1
        onPictureChange?()
    }

    func receive(_ bytes: Data) {
        guard live else { return }
        notePictureChange()
        bytes.withUnsafeBytes { buffer in
            ghostty_terminal_vt_write(terminal, buffer.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        if titleChanged {
            var value = GhosttyString()
            if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &value) == GHOSTTY_SUCCESS {
                if let ptr = value.ptr, value.len > 0 {
                    let raw = String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)
                    title = SSHTerminalDisplayText.sanitized(raw, limit: SSHTerminalDisplayText.titleLimit)
                } else {
                    title = ""
                }
            }
            titleChanged = false
        }
        if pwdChanged {
            var value = GhosttyString()
            if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &value) == GHOSTTY_SUCCESS,
               let report = SSHTerminalWorkingDirectory.report(from: Self.copy(value)) {
                if workingDirectoryHost == nil, !report.isLocal {
                    workingDirectoryHost = report.host
                }
                workingDirectory = report.folder(firstHost: workingDirectoryHost) ?? ""
            } else {
                workingDirectory = ""
            }
            pwdChanged = false
        }
        // Callbacks copy only. No channel write, await, blocking or vt reentry
        // occurs until the triggering vt_write has returned.
        flushReplies()
        if let text = pendingCopy {
            pendingCopy = nil
            if live { copied(text) }
        }
    }

    func resize(_ value: SSHTerminalGeometry) {
        geometry = value
        notePictureChange()
        forceFullRebuild = true
        ghostty_terminal_resize(terminal, UInt16(value.columns), UInt16(value.rows),
                                UInt32(value.cellWidth), UInt32(value.cellHeight))
        flushReplies()
    }

    func setColors(foreground: GhosttyColorRgb, background: GhosttyColorRgb, dark: Bool) {
        self.dark = dark
        var foreground = foreground
        var background = background
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground)
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background)
    }

    func scroll(rows: Int) {
        following = false // A drag, not output, owns follow state.
        notePictureChange()
        forceFullRebuild = true
        var value = GhosttyTerminalScrollViewportValue()
        value.delta = rows
        ghostty_terminal_scroll_viewport(terminal, .init(tag: GHOSTTY_SCROLL_VIEWPORT_DELTA, value: value))
    }

    /// Absolute row in the same space as `scrollbar.offset`.
    func scrollToRow(_ row: Int) {
        notePictureChange()
        forceFullRebuild = true
        var value = GhosttyTerminalScrollViewportValue()
        value.row = max(0, row)
        ghostty_terminal_scroll_viewport(terminal, .init(tag: GHOSTTY_SCROLL_VIEWPORT_ROW, value: value))
        var active = false
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &active)
        following = active
    }

    func backToLive() {
        following = true
        notePictureChange()
        forceFullRebuild = true
        ghostty_terminal_scroll_viewport(terminal, .init(tag: GHOSTTY_SCROLL_VIEWPORT_BOTTOM, value: .init()))
    }

    var scrollbar: GhosttyTerminalScrollbar {
        var value = GhosttyTerminalScrollbar()
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &value)
        return value
    }

    var alternateScreen: Bool {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    func mode(_ mode: GhosttyMode) -> Bool {
        var config = GhosttyTerminalModeConfig(mode: mode, value: false)
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &config)
        return config.value
    }

    var alternateScroll: Bool { mode(ghostty_mode_new(1007, false)) }

    var scrollAction: SSHTerminalScrollAction {
        SSHTerminalScrollAction.resolve(
            altScreen: alternateScreen,
            mouseReporting: mouseTracking,
            alternateScroll: alternateScroll
        )
    }

    func frame() -> SSHTerminalFrame {
        if let since = heldSince, since.duration(to: .now) >= .seconds(1) {
            var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &mode)
            heldSince = nil
        }
        if heldSince == nil { ghostty_render_state_update(render, terminal) }
        var background = GhosttyColorRgb()
        var foreground = GhosttyColorRgb()
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        var cols: UInt16 = 0
        var rowCount: UInt16 = 0
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor)
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &background)
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &foreground)
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_COLS, &cols)
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_ROWS, &rowCount)
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)
        var overscan = GhosttyRenderStateOverscan()
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_OVERSCAN, &overscan)
        let captured = Int(rowCount) + Int(overscan.below)
        let full = forceFullRebuild || cachedRows.isEmpty || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL
            || cachedRows.count != captured || (cachedRows.first?.count ?? 0) != Int(cols)
        var rebuilt = IndexSet()
        if full {
            var rows = [[SSHTerminalCell]]()
            var y = 0
            while ghostty_render_state_row_iterator_next(rowIterator) {
                rows.append(readRow(foreground: foreground, background: background))
                rebuilt.insert(y)
                y += 1
            }
            cachedRows = rows
            forceFullRebuild = false
        } else if dirty == GHOSTTY_RENDER_STATE_DIRTY_PARTIAL {
            var y: UInt16 = 0
            while ghostty_render_state_row_iterator_next_dirty(rowIterator, &y) {
                let row = readRow(foreground: foreground, background: background)
                let index = Int(y)
                if cachedRows.indices.contains(index) {
                    cachedRows[index] = row
                    rebuilt.insert(index)
                }
            }
        }
        cachedRowsChangeCount = changeCount
        if let old = cachedCursor, !Self.sameCursor(old, cursor) {
            if old.viewport_has_value { rebuilt.insert(Int(old.viewport_y)) }
            if cursor.viewport_has_value { rebuilt.insert(Int(cursor.viewport_y)) }
        }
        cachedCursor = cursor
        ghostty_render_state_clean(render)
        return .init(
            rows: cachedRows, rowsBelowViewport: cachedRows.count - Int(rowCount),
            cursor: cursor, background: background, rebuiltRows: rebuilt,
            kitty: kittyGraphics(rowsRebuilt: !rebuilt.isEmpty)
        )
    }

    // MARK: - Kitty graphics

    /// Placements for this viewport. Re-read only when the image store changed,
    /// the viewport moved, the geometry changed, or rows were rebuilt (text
    /// scrolling carries pinned placements with it). Borrowed image pointers
    /// are refreshed every frame because libghostty invalidates them on any
    /// terminal mutation.
    private func kittyGraphics(rowsRebuilt: Bool) -> SSHTerminalKittySnapshot? {
        var graphics: GhosttyKittyGraphics?
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics) == GHOSTTY_SUCCESS,
              let graphics else { return nil }
        var generation: UInt64 = 0
        guard ghostty_kitty_graphics_get(
            graphics, GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION, &generation
        ) == GHOSTTY_SUCCESS else { return nil }
        let viewportTop = Int(scrollbar.offset)
        let stored = kittySnapshot
        let reread = generation != kittyStoreGeneration || viewportTop != kittyViewportTop
            || geometry.columns != kittyStoreColumns || geometry.rows != kittyStoreRows
            || geometry.cellWidth != kittyStoreCellWidth || geometry.cellHeight != kittyStoreCellHeight
            || (rowsRebuilt && !(stored?.placements.isEmpty ?? true))
        if reread {
            kittyStoreGeneration = generation
            kittyViewportTop = viewportTop
            kittyStoreColumns = geometry.columns
            kittyStoreRows = geometry.rows
            kittyStoreCellWidth = geometry.cellWidth
            kittyStoreCellHeight = geometry.cellHeight
            kittySnapshot = readKittyGraphics(graphics, generation: generation)
        } else if stored?.images.isEmpty == false {
            stored?.refreshImageData(graphics)
        }
        guard let snapshot = kittySnapshot,
              generation != 0 || !snapshot.placements.isEmpty || !snapshot.images.isEmpty else { return nil }
        return snapshot
    }

    /// One walk of the image store into value types the renderer can place.
    /// Only real placements carry geometry; Unicode-placeholder (virtual)
    /// placements are skipped because libghostty reports no position for them.
    private func readKittyGraphics(
        _ graphics: GhosttyKittyGraphics, generation: UInt64
    ) -> SSHTerminalKittySnapshot {
        kittyPlacementReadCount &+= 1
        var placements = [SSHTerminalKittyPlacement]()
        var images = [SSHTerminalKittyImage]()
        var iterator: GhosttyKittyGraphicsPlacementIterator?
        if ghostty_kitty_graphics_placement_iterator_new(nil, &iterator) == GHOSTTY_SUCCESS,
           ghostty_kitty_graphics_get(
               graphics, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &iterator
           ) == GHOSTTY_SUCCESS {
            while ghostty_kitty_graphics_placement_next(iterator) {
                var imageID: UInt32 = 0
                var virtual = false
                var xOffset: UInt32 = 0
                var yOffset: UInt32 = 0
                var z: Int32 = 0
                ghostty_kitty_graphics_placement_get(
                    iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &imageID
                )
                ghostty_kitty_graphics_placement_get(
                    iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, &virtual
                )
                guard !virtual, let image = ghostty_kitty_graphics_image(graphics, imageID) else { continue }
                var info = GhosttyKittyGraphicsPlacementRenderInfo()
                info.size = MemoryLayout<GhosttyKittyGraphicsPlacementRenderInfo>.size
                guard ghostty_kitty_graphics_placement_render_info(
                    iterator, image, terminal, &info
                ) == GHOSTTY_SUCCESS, info.viewport_visible else { continue }
                ghostty_kitty_graphics_placement_get(
                    iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET, &xOffset
                )
                ghostty_kitty_graphics_placement_get(
                    iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET, &yOffset
                )
                ghostty_kitty_graphics_placement_get(
                    iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z, &z
                )
                placements.append(.init(
                    imageID: imageID, layer: Self.kittyLayer(z),
                    xOffset: Int(xOffset), yOffset: Int(yOffset),
                    pixelWidth: Int(info.pixel_width), pixelHeight: Int(info.pixel_height),
                    viewportColumn: Int(info.viewport_col), viewportRow: Int(info.viewport_row),
                    sourceX: Int(info.source_x), sourceY: Int(info.source_y),
                    sourceWidth: Int(info.source_width), sourceHeight: Int(info.source_height)
                ))
                if !images.contains(where: { $0.id == imageID }) {
                    images.append(SSHTerminalKittySnapshot.image(image))
                }
            }
        }
        ghostty_kitty_graphics_placement_iterator_free(iterator)
        return SSHTerminalKittySnapshot(
            generation: generation, placements: placements, images: images,
            cellWidth: geometry.cellWidth, cellHeight: geometry.cellHeight
        )
    }

    /// libghostty's own z classification: the same thresholds the placement
    /// layer filter uses, so a draw order can never disagree with it.
    private static func kittyLayer(_ z: Int32) -> SSHTerminalKittyLayer {
        if z < Int32.min / 2 { return .belowBackground }
        if z < 0 { return .belowText }
        return .aboveText
    }

    /// One row of cells. A single scalar is stored as `UInt32`; only combining
    /// graphemes allocate a `String`.
    private func readRow(foreground: GhosttyColorRgb, background: GhosttyColorRgb) -> [SSHTerminalCell] {
        ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)
        var row = [SSHTerminalCell]()
        while ghostty_render_state_row_cells_next(cells) {
            var raw: GhosttyCell = 0
            var wide = GHOSTTY_CELL_WIDE_NARROW
            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.size
            var fg = foreground
            var bg = background
            var length: UInt32 = 0
            var hasStyling = false
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &hasStyling)
            if hasStyling {
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
            }
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg)
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg)
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
            var scalar: UInt32 = 0
            var cluster: String?
            if length == 1 {
                withUnsafeMutablePointer(to: &scalar) {
                    ghostty_render_state_row_cells_get(
                        cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, $0
                    )
                }
            } else if length > 1 {
                var codepoints = [UInt32](repeating: 0, count: Int(length))
                codepoints.withUnsafeMutableBufferPointer {
                    ghostty_render_state_row_cells_get(
                        cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, $0.baseAddress
                    )
                }
                cluster = String(String.UnicodeScalarView(codepoints.compactMap(Unicode.Scalar.init)))
            }
            let width = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : (wide == GHOSTTY_CELL_WIDE_NARROW ? 1 : 0)
            row.append(.init(
                scalar: scalar, cluster: cluster, width: width,
                foreground: fg, background: bg, style: style
            ))
        }
        return row
    }

    private static func sameCursor(_ a: GhosttyRenderStateCursor, _ b: GhosttyRenderStateCursor) -> Bool {
        a.visible == b.visible && a.viewport_has_value == b.viewport_has_value
            && a.viewport_x == b.viewport_x && a.viewport_y == b.viewport_y
            && a.wide_tail == b.wide_tail && a.visual_style == b.visual_style
    }

    func key(_ key: GhosttyKey, text: String = "", modifiers: GhosttyMods = 0) -> Data {
        guard live else { return Data() }
        var event: GhosttyKeyEvent?
        guard ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS else { return Data() }
        defer { ghostty_key_event_free(event) }
        ghostty_key_encoder_setopt_from_terminal(encoder, terminal)
        // Option is Alt (Meta), like Ghostty's `macos-option-as-alt = true`.
        // The terminal-state call above resets this, so it is set per key.
        var optionAsAlt = GHOSTTY_OPTION_AS_ALT_TRUE
        ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optionAsAlt)
        ghostty_key_event_set_action(event, GHOSTTY_KEY_ACTION_PRESS)
        ghostty_key_event_set_key(event, key)
        ghostty_key_event_set_mods(event, modifiers)
        ghostty_key_event_set_unshifted_codepoint(event, text.lowercased().unicodeScalars.first?.value ?? 0)
        return text.utf8CString.withUnsafeBufferPointer { input in
            ghostty_key_event_set_utf8(event, input.baseAddress, input.count - 1)
            var length = 0
            ghostty_key_encoder_encode(encoder, event, nil, 0, &length)
            var output = [CChar](repeating: 0, count: length)
            let result = output.withUnsafeMutableBufferPointer {
                ghostty_key_encoder_encode(encoder, event, $0.baseAddress, $0.count, &length)
            }
            guard result == GHOSTTY_SUCCESS else { return Data() }
            return output.withUnsafeBytes { Data($0.prefix(length)) }
        }
    }

    /// True while libghostty reports the cursor in the shell's own input
    /// (OSC 133 A/B): what is typed there is a command line, not a secret.
    var cursorAtPrompt: Bool {
        var value = false
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT, &value)
        return live && value
    }

    /// The text left of the cursor on the cursor's row, from the live viewport
    /// snapshot. nil when the viewport is scrolled into history, when the
    /// cursor is hidden (a half-drawn frame, or a program that hides it), and
    /// until a paint has snapshotted the newest output: the caller keeps its
    /// state rather than acting on a row the user is not looking at.
    var cursorLineBeforeCursor: String? {
        guard live, following, cachedRowsChangeCount == changeCount else { return nil }
        guard let cursor = cachedCursor, cursor.viewport_has_value, cursor.visible else { return nil }
        let row = Int(cursor.viewport_y)
        guard cachedRows.indices.contains(row) else { return nil }
        return cachedRows[row].prefix(Int(cursor.viewport_x)).map(\.text).joined()
    }

    /// The cursor's cell in the active area.
    var cursorCell: (column: Int, row: Int) {
        var x: UInt16 = 0
        var y: UInt16 = 0
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        return (Int(x), Int(y))
    }

    /// ⌘K, as Ghostty does it: never on the alternate screen, where a full-
    /// screen app owns every row. Local history goes. At a shell prompt known
    /// from OSC 133 the screen is cleared and a form feed is returned for the
    /// caller to send, so the shell redraws its prompt. Elsewhere the rows
    /// above the cursor go, the cursor row moves to the top, and nothing is
    /// sent. The local sequences are written only between remote sequences.
    func clearScreen() -> Data {
        guard live, !alternateScreen else { return Data() }
        var ground = false
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_VT_GROUND, &ground)
        guard ground else { return Data() }
        let atPrompt = cursorAtPrompt
        let row = cursorCell.row
        // ED 2 at a prompt moves the screen into history, so ED 3 runs last.
        let local = if atPrompt {
            "\u{1b}[2J\u{1b}[3J"
        } else if row > 0 {
            "\u{1b}[\(row)S\u{1b}[\(row)A\u{1b}[3J"
        } else {
            "\u{1b}[3J"
        }
        let bytes = Data(local.utf8)
        bytes.withUnsafeBytes { buffer in
            ghostty_terminal_vt_write(terminal, buffer.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        backToLive()
        return atPrompt ? Data([0x0C]) : Data()
    }

    /// True while the remote application asked for mouse reports (Herdr, tmux
    /// with `mouse on`, vim, …). Touches then belong to it, not local history.
    var mouseTracking: Bool {
        var value = false
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &value)
        return live && value
    }

    enum MouseInput {
        case click
        case press
        case motion
        case release
        case wheelUp
        case wheelDown
    }

    /// Encodes a touch as mouse report(s) at a viewport cell, in the protocol
    /// and tracking mode the application selected. Empty when it did not ask.
    func mouse(_ input: MouseInput, column: Int, row: Int) -> Data {
        guard mouseTracking else { return Data() }
        ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, terminal)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = UInt32(geometry.pixelWidth)
        size.screen_height = UInt32(geometry.pixelHeight)
        size.cell_width = UInt32(max(1, geometry.cellWidth))
        size.cell_height = UInt32(max(1, geometry.cellHeight))
        ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
        let column = min(max(0, column), geometry.columns - 1)
        let row = min(max(0, row), geometry.rows - 1)
        let position = GhosttyMousePosition(x: Float((Double(column) + 0.5) * Double(geometry.cellWidth)),
                                            y: Float((Double(row) + 0.5) * Double(geometry.cellHeight)))
        let events: [(GhosttyMouseAction, GhosttyMouseButton, Bool)] = switch input {
        case .click: [
            (GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT, true),
            (GHOSTTY_MOUSE_ACTION_RELEASE, GHOSTTY_MOUSE_BUTTON_LEFT, false),
        ]
        case .press: [(GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT, true)]
        case .motion: [(GHOSTTY_MOUSE_ACTION_MOTION, GHOSTTY_MOUSE_BUTTON_LEFT, true)]
        case .release: [(GHOSTTY_MOUSE_ACTION_RELEASE, GHOSTTY_MOUSE_BUTTON_LEFT, false)]
        case .wheelUp: [(GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_FOUR, false)]
        case .wheelDown: [(GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_FIVE, false)]
        }
        var output = Data()
        for (action, button, pressed) in events {
            var event: GhosttyMouseEvent?
            guard ghostty_mouse_event_new(nil, &event) == GHOSTTY_SUCCESS else { return Data() }
            defer { ghostty_mouse_event_free(event) }
            ghostty_mouse_event_set_action(event, action)
            ghostty_mouse_event_set_button(event, button)
            ghostty_mouse_event_set_position(event, position)
            var anyPressed = pressed
            ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &anyPressed)
            var buffer = [CChar](repeating: 0, count: 64)
            var length = 0
            let result = buffer.withUnsafeMutableBufferPointer {
                ghostty_mouse_encoder_encode(mouseEncoder, event, $0.baseAddress, $0.count, &length)
            }
            guard result == GHOSTTY_SUCCESS else { continue }
            output.append(buffer.withUnsafeBytes { Data($0.prefix(length)) })
        }
        return output
    }

    /// Ghostty default word boundaries except `:`. `/` was never a boundary,
    /// so paths stay one word. Dropping colon keeps `https://…` as one word.
    private static let wordBoundaries: [UInt32] = [
        0,
        0x20, 0x09, 0x27, 0x22, 0x2502, 0x60, 0x7C,
        0x3B, 0x2C, 0x28, 0x29, 0x5B, 0x5D, 0x7B, 0x7D, 0x3C, 0x3E, 0x24,
    ]

    /// Word under a viewport cell. Paths and URLs count as one word.
    func selectWord(column: Int, row: Int) -> SSHTerminalSelectionSnapshot? {
        guard let ref = viewportRef(column: column, row: row) else { return nil }
        return Self.wordBoundaries.withUnsafeBufferPointer { buffer in
            var options = GhosttyTerminalSelectWordOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectWordOptions>.size
            options.ref = ref
            options.boundary_codepoints = buffer.baseAddress
            options.boundary_codepoints_len = buffer.count
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            guard ghostty_terminal_select_word(terminal, &options, &selection) == GHOSTTY_SUCCESS else {
                return nil
            }
            guard let snapshot = snapshot(selection) else { return nil }
            return SSHTerminalWordCopy.applyingTrailingColonTrim(snapshot)
        }
    }

    /// The cell under a hold, with the same word the double tap would copy and
    /// the OSC 8 hyperlink it carries, if any.
    func heldCell(column: Int, row: Int) -> SSHTerminalHeldCell? {
        let word = selectWord(column: column, row: row)
        let link = hyperlink(column: column, row: row)
        guard word != nil || link != nil else { return nil }
        return SSHTerminalHeldCell(
            text: word?.text ?? "", spans: word?.spans ?? [], hyperlink: link
        )
    }

    /// The OSC 8 URI of a viewport cell. Empty when the cell has no link.
    func hyperlink(column: Int, row: Int) -> String? {
        guard var ref = viewportRef(column: column, row: row) else { return nil }
        var length = 0
        _ = ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &length)
        guard length > 0, length <= 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        var written = 0
        guard ghostty_grid_ref_hyperlink_uri(&ref, &buffer, length, &written) == GHOSTTY_SUCCESS,
              written > 0 else { return nil }
        return String(decoding: buffer[..<written], as: UTF8.self)
    }

    func beginSelection(column: Int, row: Int, surfacePoint: CGPoint) {
        guard let selectionGesture, let selectionPress else { return }
        ghostty_selection_gesture_reset(selectionGesture, terminal)
        guard var ref = viewportRef(column: column, row: row) else { return }
        ghostty_selection_gesture_event_set(
            selectionPress, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref
        )
        var position = GhosttySurfacePosition(x: surfacePoint.x, y: surfacePoint.y)
        ghostty_selection_gesture_event_set(
            selectionPress, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position
        )
        _ = ghostty_selection_gesture_event(selectionGesture, terminal, selectionPress, nil)
    }

    func dragSelection(column: Int, row: Int, surfacePoint: CGPoint) -> SSHTerminalSelectionSnapshot? {
        guard let selectionGesture, let selectionDrag else { return nil }
        guard var ref = viewportRef(column: column, row: row) else { return nil }
        ghostty_selection_gesture_event_set(
            selectionDrag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref
        )
        var position = GhosttySurfacePosition(x: surfacePoint.x, y: surfacePoint.y)
        ghostty_selection_gesture_event_set(
            selectionDrag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position
        )
        var gestureGeometry = GhosttySelectionGestureGeometry(
            columns: UInt32(max(1, self.geometry.columns)),
            cell_width: UInt32(max(1, self.geometry.cellWidth)),
            padding_left: 0,
            screen_height: UInt32(max(1, self.geometry.pixelHeight))
        )
        ghostty_selection_gesture_event_set(
            selectionDrag, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &gestureGeometry
        )
        var selection = GhosttySelection()
        selection.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_selection_gesture_event(
            selectionGesture, terminal, selectionDrag, &selection
        ) == GHOSTTY_SUCCESS else { return nil }
        return snapshot(selection)
    }

    func endSelection(column: Int, row: Int) {
        guard let selectionGesture, let selectionRelease else { return }
        if var ref = viewportRef(column: column, row: row) {
            ghostty_selection_gesture_event_set(
                selectionRelease, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref
            )
        } else {
            ghostty_selection_gesture_event_set(
                selectionRelease, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, nil
            )
        }
        _ = ghostty_selection_gesture_event(selectionGesture, terminal, selectionRelease, nil)
    }

    func cancelSelection() {
        guard let selectionGesture else { return }
        ghostty_selection_gesture_reset(selectionGesture, terminal)
    }

    /// A row past the bottom is the history row drawn in the strip under the
    /// viewport while history rests between rows. At live there is none, and
    /// it falls back to the last viewport row.
    private func viewportRef(column: Int, row: Int) -> GhosttyGridRef? {
        let column = min(max(0, column), max(0, geometry.columns - 1))
        if row >= geometry.rows,
           let below = gridRef(.init(x: UInt16(column), y: UInt32(scrollbar.offset) + UInt32(geometry.rows)), tag: GHOSTTY_POINT_TAG_SCREEN) {
            return below
        }
        let row = min(max(0, row), max(0, geometry.rows - 1))
        return gridRef(.init(x: UInt16(column), y: UInt32(row)), tag: GHOSTTY_POINT_TAG_VIEWPORT)
    }

    private func gridRef(_ coordinate: GhosttyPointCoordinate, tag: GhosttyPointTag) -> GhosttyGridRef? {
        var value = GhosttyPointValue()
        value.coordinate = coordinate
        let point = GhosttyPoint(tag: tag, value: value)
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { return nil }
        return ref
    }

    private func snapshot(_ selection: GhosttySelection) -> SSHTerminalSelectionSnapshot? {
        guard let text = formatSelection(selection), !text.isEmpty else { return nil }
        return SSHTerminalSelectionSnapshot(text: text, spans: viewportSpans(selection))
    }

    private func formatSelection(_ selection: GhosttySelection) -> String? {
        var selection = selection
        var options = GhosttyTerminalSelectionFormatOptions()
        options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
        options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
        options.unwrap = true
        options.trim = true
        return withUnsafePointer(to: &selection) { pointer in
            options.selection = pointer
            var output: UnsafeMutablePointer<UInt8>?
            var length = 0
            let result = ghostty_terminal_selection_format_alloc(
                terminal, nil, options, &output, &length
            )
            defer { ghostty_free(nil, output, length) }
            guard result == GHOSTTY_SUCCESS, let output, length > 0 else { return nil }
            return String(decoding: UnsafeBufferPointer(start: output, count: length), as: UTF8.self)
        }
    }

    private func viewportSpans(_ selection: GhosttySelection) -> [SSHTerminalSelectionSpan] {
        var selection = selection
        var ordered = GhosttySelection()
        ordered.size = MemoryLayout<GhosttySelection>.size
        guard ghostty_terminal_selection_ordered(
            terminal, &selection, GHOSTTY_SELECTION_ORDER_FORWARD, &ordered
        ) == GHOSTTY_SUCCESS else { return [] }
        // Screen rows less the viewport's top, so a selection reaching the
        // strip under the viewport (see `viewportRef`) highlights there too.
        let viewportTop = Int(scrollbar.offset)
        func visible(_ ref: inout GhosttyGridRef) -> (x: Int, y: Int)? {
            var point = GhosttyPointCoordinate()
            guard ghostty_terminal_point_from_grid_ref(
                terminal, &ref, GHOSTTY_POINT_TAG_SCREEN, &point
            ) == GHOSTTY_SUCCESS else { return nil }
            return (Int(point.x), Int(point.y) - viewportTop)
        }
        let lastCol = max(0, geometry.columns - 1)
        let lastRow = max(0, geometry.rows)
        guard let start = visible(&ordered.start), let end = visible(&ordered.end),
              start.y <= lastRow, end.y >= 0 else { return [] }
        let (startX, startY) = start.y < 0 ? (0, 0) : start
        let (endX, endY) = end.y > lastRow ? (lastCol, lastRow) : end
        let top = startY
        let bottom = endY
        if top == bottom {
            let lo = max(0, min(startX, endX))
            let hi = min(lastCol, max(startX, endX))
            return [SSHTerminalSelectionSpan(row: top, startColumn: lo, endColumn: hi)]
        }
        var spans = [SSHTerminalSelectionSpan]()
        spans.append(SSHTerminalSelectionSpan(row: top, startColumn: startX, endColumn: lastCol))
        if bottom > top + 1 {
            for row in (top + 1)..<bottom {
                spans.append(SSHTerminalSelectionSpan(row: row, startColumn: 0, endColumn: lastCol))
            }
        }
        spans.append(SSHTerminalSelectionSpan(row: bottom, startColumn: 0, endColumn: endX))
        return spans
    }

    static func pasteIsSafe(_ text: String) -> Bool {
        text.utf8CString.withUnsafeBufferPointer { ghostty_paste_is_safe($0.baseAddress, $0.count - 1) }
    }

    /// `ghostty_paste_is_safe` rejects only LF and the bracketed-paste
    /// terminator. A CR also submits a command when bracketed paste is off, and
    /// other C0 bytes are silently blanked, so those need consent too. Tab is the
    /// only control character that is ordinary pasted text.
    static func pasteNeedsConfirmation(_ text: String) -> Bool {
        !pasteIsSafe(text) || text.unicodeScalars.contains { ($0.value < 32 && $0 != "\t") || $0.value == 127 }
    }

    /// Lines the paste would submit: CR, LF and CRLF each end one, and a
    /// trailing terminator does not start another.
    static func pasteLineCount(_ text: String) -> Int {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return max(1, lines.count)
    }

    func paste(_ text: String, confirmed: Bool) throws -> Data {
        guard live else { throw SSHTerminalError.disconnected }
        guard text.utf8.count <= Self.maximumPasteBytes else { throw SSHTerminalError.pasteTooLarge }
        guard confirmed || !Self.pasteNeedsConfirmation(text) else { throw SSHTerminalError.unsafePaste }
        var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2004, false), value: false)
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &mode)
        var input = text.utf8CString
        var output = [CChar](repeating: 0, count: input.count + 12)
        var written = 0
        let result = input.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                ghostty_paste_encode(source.baseAddress, source.count - 1, mode.value,
                                     destination.baseAddress, destination.count, &written)
            }
        }
        guard result == GHOSTTY_SUCCESS else { throw SSHTerminalError.engineUnavailable }
        return output.withUnsafeBytes { Data($0.prefix(written)) }
    }

    /// The only bytes that may reach the PTY from the terminal's own replies.
    /// The NULL clipboard read callback can still generate an empty OSC 52 or
    /// denied Kitty reply upstream, so the families are fixed: CSI status/size/mode
    /// reports, DCS DA/version reports, Kitty graphics APC replies (the `OK` or
    /// `EINVAL` a program waits for after a transmission or `a=q` query), and
    /// the OSC 7501 support reply
    /// `ESC ] 7501 ; ? (: key=value)* ST` (ST = `ESC \` or BEL). Revision 0.4
    /// lets the reply list what the terminal accepts, such as
    /// `?:states=idle,working,done,blocked,error:kinds=permission,question,auth`;
    /// keys are `[a-z]+` and values use the spec's value set, which has no
    /// control bytes, `;`, or `:`. No other OSC response (including clipboard)
    /// is forwarded.
    nonisolated static func isApprovedReply(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard bytes.count >= 2, bytes[0] == 0x1b else { return false }
        if bytes[1] == 0x5b || bytes[1] == 0x50 { return true }
        // Kitty graphics reply: APC `ESC _ G ... ESC \`.
        if bytes[1] == 0x5f {
            guard bytes.count >= 4, bytes[2] == 0x47 else { return false }
            return bytes[bytes.count - 2] == 0x1b && bytes[bytes.count - 1] == 0x5c
        }
        let query: [UInt8] = [0x1b, 0x5d, 0x37, 0x35, 0x30, 0x31, 0x3b, 0x3f] // ESC ] 7501 ; ?
        guard bytes.count <= 512, bytes.starts(with: query) else { return false }
        var body = bytes.dropFirst(query.count)
        if body.last == 0x07 {
            body = body.dropLast()
        } else if body.count >= 2, body[body.endIndex - 2] == 0x1b, body.last == 0x5c {
            body = body.dropLast(2)
        } else {
            return false
        }
        guard !body.isEmpty else { return true }
        guard body.first == 0x3a else { return false } // ':'
        return body.dropFirst().split(separator: 0x3a, omittingEmptySubsequences: false).allSatisfy(isProgramStatusPair)
    }

    /// `key=value` with key `[a-z]+` and value `[A-Za-z0-9_.,+/=-]*`.
    nonisolated private static func isProgramStatusPair(_ pair: UnsafeBufferPointer<UInt8>.SubSequence) -> Bool {
        guard let equals = pair.firstIndex(of: 0x3d) else { return false }
        let key = pair[pair.startIndex..<equals]
        guard !key.isEmpty, key.allSatisfy({ (0x61...0x7a).contains($0) }) else { return false }
        return pair[pair.index(after: equals)...].allSatisfy { byte in
            switch byte {
            case 0x30...0x39, 0x41...0x5a, 0x61...0x7a: true
            case UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: ","), UInt8(ascii: "+"),
                 UInt8(ascii: "/"), UInt8(ascii: "="), UInt8(ascii: "-"): true
            default: false
            }
        }
    }

    nonisolated private static func copy(_ string: GhosttyString) -> String {
        guard let ptr = string.ptr else { return "" }
        return String(decoding: UnsafeBufferPointer(start: ptr, count: string.len), as: UTF8.self)
    }

    private func flushReplies() {
        let pending = replies
        replies.removeAll(keepingCapacity: true)
        guard live else { return }
        for reply in pending { sink(reply) }
    }

    private func installEffects() {
        let write: GhosttyTerminalWritePtyFn = { _, context, bytes, count in
            MainActor.assumeIsolated {
                guard let context, let bytes else { return }
                // C function pointers cannot capture dynamic Self.
                // swiftlint:disable:next prefer_self_in_static_references
                guard SSHTerminalEngine.isApprovedReply(UnsafeBufferPointer(start: bytes, count: count)) else { return }
                let owner = Unmanaged<SSHTerminalEngine>.fromOpaque(context).takeUnretainedValue()
                if owner.live { owner.replies.append(Data(bytes: bytes, count: count)) }
            }
        }
        let attributes: GhosttyTerminalDeviceAttributesFn = { _, _, out in
            guard let out else { return false }
            out.pointee = GhosttyDeviceAttributes()
            out.pointee.primary.conformance_level = 62
            out.pointee.primary.features.0 = 22 // ANSI color, not clipboard support.
            out.pointee.primary.num_features = 1
            out.pointee.secondary.device_type = 1
            return true
        }
        let size: GhosttyTerminalSizeFn = { _, context, out in
            MainActor.assumeIsolated {
                guard let context, let out else { return false }
                let geometry = Unmanaged<SSHTerminalEngine>.fromOpaque(context).takeUnretainedValue().geometry
                out.pointee = .init(rows: UInt16(geometry.rows), columns: UInt16(geometry.columns),
                                    cell_width: UInt32(geometry.cellWidth), cell_height: UInt32(geometry.cellHeight))
                return true
            }
        }
        let version: GhosttyTerminalXtversionFn = { _, _ in
            // StaticString owns a process-lifetime literal. No borrowed engine
            // data or non-Sendable C struct crosses an isolation boundary.
            let value: StaticString = "Oppi"
            return GhosttyString(ptr: value.utf8Start, len: value.utf8CodeUnitCount)
        }
        let scheme: GhosttyTerminalColorSchemeFn = { _, context, out in
            MainActor.assumeIsolated {
                guard let context, let out else { return false }
                let owner = Unmanaged<SSHTerminalEngine>.fromOpaque(context).takeUnretainedValue()
                out.pointee = owner.dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
                return true
            }
        }
        let title: GhosttyTerminalTitleChangedFn = { _, context in
            MainActor.assumeIsolated {
                guard let context else { return }
                Unmanaged<SSHTerminalEngine>.fromOpaque(context).takeUnretainedValue().titleChanged = true
            }
        }
        let pwd: GhosttyTerminalPwdChangedFn = { _, context in
            MainActor.assumeIsolated {
                guard let context else { return }
                Unmanaged<SSHTerminalEngine>.fromOpaque(context).takeUnretainedValue().pwdChanged = true
            }
        }
        let hold: GhosttyTerminalRenderHoldFn = { terminal, context, held in
            MainActor.assumeIsolated {
                guard let context else { return }
                let owner = Unmanaged<SSHTerminalEngine>.fromOpaque(context).takeUnretainedValue()
                if held { ghostty_render_state_update(owner.render, terminal) }
                owner.heldSince = held ? .now : nil
            }
        }
        // Both copy into a pure-Swift store; strings are valid only during the call.
        let status: GhosttyTerminalProgramStatusFn = { _, context, report in
            MainActor.assumeIsolated {
                guard let context, let report else { return }
                let value = report.pointee
                Unmanaged<SSHTerminalEngine>.fromOpaque(context).takeUnretainedValue().programStatus.apply(.init(
                    state: value.state, kind: value.kind, progress: Int(value.progress),
                    // swiftlint:disable:next prefer_self_in_static_references
                    id: SSHTerminalEngine.copy(value.id), app: SSHTerminalEngine.copy(value.app),
                    // swiftlint:disable:next prefer_self_in_static_references
                    title: SSHTerminalEngine.copy(value.title), message: SSHTerminalEngine.copy(value.message)))
            }
        }
        // Copy into the alert feed only; the screen decides what to show.
        let notification: GhosttyTerminalDesktopNotificationFn = { _, context, request in
            MainActor.assumeIsolated {
                guard let context, let request else { return }
                let value = request.pointee
                Unmanaged<SSHTerminalEngine>.fromOpaque(context).takeUnretainedValue().alerts.notify(
                    // swiftlint:disable:next prefer_self_in_static_references
                    title: SSHTerminalEngine.copy(value.title), body: SSHTerminalEngine.copy(value.body))
            }
        }
        let bell: GhosttyTerminalBellFn = { _, context in
            MainActor.assumeIsolated {
                guard let context else { return }
                Unmanaged<SSHTerminalEngine>.fromOpaque(context).takeUnretainedValue().alerts.ring()
            }
        }
        let prompt: GhosttyTerminalSemanticPromptFn = { _, context, event in
            MainActor.assumeIsolated {
                guard let context, let event, event.pointee.kind == GHOSTTY_SEMANTIC_PROMPT_PROMPT_START else { return }
                Unmanaged<SSHTerminalEngine>.fromOpaque(context).takeUnretainedValue().programStatus.promptStarted()
            }
        }
        // Standard clipboard, non-empty UTF-8 text only. Clearing, the X11
        // selection/primary buffers, and other MIME types are refused, so a
        // remote program cannot wipe the clipboard or write binary to it.
        let clipboard: GhosttyTerminalClipboardWriteFn = { _, context, write in
            MainActor.assumeIsolated {
                guard let context, let write else { return }
                let request = write.pointee
                var reply = GhosttyClipboardWriteReply()
                reply.size = MemoryLayout<GhosttyClipboardWriteReply>.size
                reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED
                defer { request.reply?(write, &reply) }
                guard request.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD, let contents = request.contents else { return }
                // swiftlint:disable:next prefer_self_in_static_references
                let text = UnsafeBufferPointer(start: contents, count: request.contents_len).first { SSHTerminalEngine.copy($0.mime) == "text/plain" }
                guard let text else {
                    reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
                    return
                }
                // swiftlint:disable:next prefer_self_in_static_references
                guard let ptr = text.data.ptr, text.data.len > 0, text.data.len <= SSHTerminalEngine.maximumCopyBytes,
                      let value = String(bytes: UnsafeBufferPointer(start: ptr, count: text.data.len), encoding: .utf8) else {
                    reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA
                    return
                }
                let owner = Unmanaged<SSHTerminalEngine>.fromOpaque(context).takeUnretainedValue()
                guard owner.live else { return }
                owner.pendingCopy = value
                reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
            }
        }
        // A full reset also reports a status clear first; this keeps RIS clearing
        // records even if that report were ever missing. libghostty clears its
        // title on RIS without calling TITLE_CHANGED, so the shown title resets here.
        let reset: GhosttyTerminalResetFn = { _, context in
            MainActor.assumeIsolated {
                guard let context else { return }
                let owner = Unmanaged<SSHTerminalEngine>.fromOpaque(context).takeUnretainedValue()
                owner.programStatus.removeAll()
                owner.title = ""
                owner.titleChanged = false
                owner.workingDirectory = ""
                owner.workingDirectoryHost = nil
                owner.pwdChanged = false
            }
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, unsafeBitCast(status, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, unsafeBitCast(notification, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, unsafeBitCast(prompt, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RESET, unsafeBitCast(reset, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(write, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, unsafeBitCast(attributes, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, unsafeBitCast(version, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(scheme, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(title, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PWD_CHANGED, unsafeBitCast(pwd, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, unsafeBitCast(hold, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(clipboard, to: UnsafeRawPointer.self))
        // The write callback enables Kitty clipboard (OSC 5522) writes, which
        // buffer up to 64 MiB by default before the callback sees them.
        var copyLimit = Self.maximumCopyBytes
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE_MAX_BYTES, &copyLimit)
    }
}

/// Repeats a held hardware key. UIKit delivers pressesBegan once, so the owner
/// re-sends the encoded key after an initial delay and then at a fixed rate
/// until `stop()` or the action returns false (e.g. the session ended).
@MainActor
final class SSHTerminalKeyRepeater {
    private let initialDelay: Duration
    private let interval: Duration
    private var task: Task<Void, Never>?

    init(initialDelay: Duration = .milliseconds(400), interval: Duration = .milliseconds(50)) {
        self.initialDelay = initialDelay
        self.interval = interval
    }

    func start(_ action: @escaping @MainActor () -> Bool) {
        task?.cancel()
        task = Task { [initialDelay, interval] in
            try? await Task.sleep(for: initialDelay)
            while !Task.isCancelled {
                guard action() else { return }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Shared by both terminal bars: modifiers affect one key, not a paste or
/// the whole chord. Switching keyboards does not lose the pending modifier.
struct SSHTerminalModifierLatch {
    private(set) var modifiers: GhosttyMods = 0

    func isArmed(_ modifier: GhosttyMods) -> Bool { modifiers & modifier != 0 }
    mutating func toggle(_ modifier: GhosttyMods) { modifiers ^= modifier }

    mutating func take() -> GhosttyMods {
        defer { modifiers = 0 }
        return modifiers
    }
}

enum SSHTerminalError: Error {
    case engineUnavailable, disconnected, pasteTooLarge, unsafePaste
}
