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
    let text: String
    let width: Int
    let foreground: GhosttyColorRgb
    let background: GhosttyColorRgb
    let style: GhosttyStyle
}

struct SSHTerminalFrame {
    let rows: [[SSHTerminalCell]]
    let cursor: GhosttyRenderStateCursor
    let background: GhosttyColorRgb
}

/// Separate from the passive log owner. All C access (including callbacks and
/// borrowed render data) runs synchronously on MainActor. Frames own their text
/// and value structs; no borrowed pointer escapes to UIKit. Paint is coalesced
/// by the surface, never interpretation. Effects start NULL and only the ten
/// entries below gain authority; in particular there is no clipboard callback.
@MainActor
final class SSHTerminalEngine {
    static let maximumPasteBytes = 64 * 1024
    private var terminal: GhosttyTerminal?
    private var render: GhosttyRenderState?
    private var rowIterator: GhosttyRenderStateRowIterator?
    private var cells: GhosttyRenderStateRowCells?
    private var encoder: GhosttyKeyEncoder?
    private var mouseEncoder: GhosttyMouseEncoder?
    private var replies = [Data]()
    private var live = true
    private var titleChanged = false
    private var heldSince: ContinuousClock.Instant?
    private let sink: (Data) -> Void
    private(set) var title = ""
    /// OSC 7501 records for this terminal. Outlives `close()` so unseen
    /// `done`/`error` records can still be shown after the program exits.
    let programStatus = SSHTerminalProgramStatusStore()
    private(set) var geometry: SSHTerminalGeometry
    private(set) var following = true
    /// Bumped by anything that can change the picture. The display link repaints
    /// when it moved, so output never invalidates SwiftUI.
    private(set) var changeCount = 0
    var dark = true
    var renderHeld: Bool { heldSince != nil }

    init(geometry: SSHTerminalGeometry = .init(), sink: @escaping (Data) -> Void) throws {
        self.geometry = geometry
        self.sink = sink
        guard ghostty_terminal_new(nil, &terminal, UInt16(geometry.columns), UInt16(geometry.rows)) == GHOSTTY_SUCCESS,
              ghostty_render_state_new(nil, &render) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_iterator_new(nil, &rowIterator) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS,
              ghostty_key_encoder_new(nil, &encoder) == GHOSTTY_SUCCESS,
              ghostty_mouse_encoder_new(nil, &mouseEncoder) == GHOSTTY_SUCCESS else {
            throw SSHTerminalError.engineUnavailable
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        installEffects()
        var historyLimit: Int = 8 * 1024 * 1024
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &historyLimit)
    }

    isolated deinit {
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
        programStatus.processEnded()
    }

    func receive(_ bytes: Data) {
        guard live else { return }
        changeCount &+= 1
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
        // Callbacks copy only. No channel write, await, blocking or vt reentry
        // occurs until the triggering vt_write has returned.
        flushReplies()
    }

    func resize(_ value: SSHTerminalGeometry) {
        geometry = value
        changeCount &+= 1
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
        changeCount &+= 1
        var value = GhosttyTerminalScrollViewportValue()
        value.delta = rows
        ghostty_terminal_scroll_viewport(terminal, .init(tag: GHOSTTY_SCROLL_VIEWPORT_DELTA, value: value))
    }

    func backToLive() {
        following = true
        changeCount &+= 1
        ghostty_terminal_scroll_viewport(terminal, .init(tag: GHOSTTY_SCROLL_VIEWPORT_BOTTOM, value: .init()))
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
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor)
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_COLOR_BACKGROUND, &background)
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_COLOR_FOREGROUND, &foreground)
        ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)
        var rows = [[SSHTerminalCell]]()
        while ghostty_render_state_row_iterator_next(rowIterator) {
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
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg)
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg)
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
                var codepoints = [UInt32](repeating: 0, count: Int(length))
                if length > 0 {
                    codepoints.withUnsafeMutableBufferPointer {
                        ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, $0.baseAddress)
                    }
                }
                let text = String(String.UnicodeScalarView(codepoints.compactMap(Unicode.Scalar.init)))
                let width = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : (wide == GHOSTTY_CELL_WIDE_NARROW ? 1 : 0)
                row.append(.init(text: text, width: width, foreground: fg, background: bg, style: style))
            }
            rows.append(row)
        }
        ghostty_render_state_clean(render)
        return .init(rows: rows, cursor: cursor, background: background)
    }

    func key(_ key: GhosttyKey, text: String = "", modifiers: GhosttyMods = 0) -> Data {
        guard live else { return Data() }
        var event: GhosttyKeyEvent?
        guard ghostty_key_event_new(nil, &event) == GHOSTTY_SUCCESS else { return Data() }
        defer { ghostty_key_event_free(event) }
        ghostty_key_encoder_setopt_from_terminal(encoder, terminal)
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

    /// True while the remote application asked for mouse reports (Herdr, tmux
    /// with `mouse on`, vim, …). Touches then belong to it, not local history.
    var mouseTracking: Bool {
        var value = false
        ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &value)
        return live && value
    }

    enum MouseInput {
        case click
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
        let events: [(GhosttyMouseAction, GhosttyMouseButton)] = switch input {
        case .click: [(GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT), (GHOSTTY_MOUSE_ACTION_RELEASE, GHOSTTY_MOUSE_BUTTON_LEFT)]
        case .wheelUp: [(GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_FOUR)]
        case .wheelDown: [(GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_FIVE)]
        }
        var output = Data()
        for (action, button) in events {
            var event: GhosttyMouseEvent?
            guard ghostty_mouse_event_new(nil, &event) == GHOSTTY_SUCCESS else { return Data() }
            defer { ghostty_mouse_event_free(event) }
            ghostty_mouse_event_set_action(event, action)
            ghostty_mouse_event_set_button(event, button)
            ghostty_mouse_event_set_position(event, position)
            var pressed = action == GHOSTTY_MOUSE_ACTION_PRESS && input == .click
            ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)
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
    /// NULL clipboard callbacks can still generate an empty OSC 52 or denied
    /// Kitty reply upstream, so the families are fixed: CSI status/size/mode
    /// reports, DCS DA/version reports, and exactly the OSC 7501 support reply
    /// `ESC ] 7501 ; ? ST` (ST = `ESC \` or BEL). No other OSC response
    /// (including clipboard, and no 7501 reply with anything after the `?`)
    /// is forwarded.
    nonisolated static func isApprovedReply(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard bytes.count >= 2, bytes[0] == 0x1b else { return false }
        if bytes[1] == 0x5b || bytes[1] == 0x50 { return true }
        let query: [UInt8] = [0x1b, 0x5d, 0x37, 0x35, 0x30, 0x31, 0x3b, 0x3f] // ESC ] 7501 ; ?
        guard bytes.count == query.count + 1 || bytes.count == query.count + 2,
              bytes.prefix(query.count).elementsEqual(query) else { return false }
        let terminator = Array(bytes.dropFirst(query.count))
        return terminator == [0x07] || terminator == [0x1b, 0x5c]
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
                    id: SSHTerminalEngine.copy(value.id), app: SSHTerminalEngine.copy(value.app),
                    title: SSHTerminalEngine.copy(value.title), message: SSHTerminalEngine.copy(value.message)))
            }
        }
        let prompt: GhosttyTerminalSemanticPromptFn = { _, context, event in
            MainActor.assumeIsolated {
                guard let context, let event, event.pointee.kind == GHOSTTY_SEMANTIC_PROMPT_PROMPT_START else { return }
                Unmanaged<SSHTerminalEngine>.fromOpaque(context).takeUnretainedValue().programStatus.promptStarted()
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
            }
        }
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, unsafeBitCast(status, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, unsafeBitCast(prompt, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RESET, unsafeBitCast(reset, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(write, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, unsafeBitCast(attributes, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, unsafeBitCast(version, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(scheme, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(title, to: UnsafeRawPointer.self))
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, unsafeBitCast(hold, to: UnsafeRawPointer.self))
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
