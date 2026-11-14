import Foundation

/// How large a file the app downloads from the server to this device, for
/// Share, Save to Files, or Quick Look. The download goes to disk, never into
/// memory, so the limits are about disk and time, not the app's footprint.
enum FileDownloadBudget {
    /// 2 GB: what a 5 Mbit/s link, a slow remote connection, moves within the
    /// one-hour resource timeout a file download gets (`remoteFileShare`).
    /// Larger files belong on a computer, not a phone's temporary folder.
    /// Decimal, as the file sizes the app shows are.
    static let maxBytes: Int64 = 2_000_000_000

    /// Why a download does not start, or stops.
    enum Refusal: Equatable {
        case overLimit(byteCount: Int64)
        /// The device has `availableBytes` free and the download needs `neededBytes`.
        case notEnoughSpace(neededBytes: Int64, availableBytes: Int64)

        var title: String {
            switch self {
            case .overLimit: String(localized: "File Too Large to Download")
            case .notEnoughSpace: String(localized: "Not Enough Storage")
            }
        }

        func message(fileName: String) -> String {
            switch self {
            case .overLimit(let byteCount):
                let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
                let limit = ByteCountFormatter.string(fromByteCount: maxBytes, countStyle: .file)
                return String(localized: "“\(fileName)” is \(size). Oppi downloads files up to \(limit) to this device.")
            case .notEnoughSpace(let needed, let available):
                let neededText = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
                let availableText = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                return String(localized: "“\(fileName)” needs \(neededText) free on this device, and \(availableText) is free.")
            }
        }
    }

    /// The refusal for a file of `byteCount` bytes on a device with
    /// `availableBytes` free, or nil when it may download. Nil sizes are not
    /// known and pass. The download needs room for itself and for the copy
    /// that Save to Files or a receiving app makes of it.
    static func refusal(byteCount: Int64?, availableBytes: Int64?) -> Refusal? {
        guard let byteCount else { return nil }
        if byteCount > maxBytes { return .overLimit(byteCount: byteCount) }
        let needed = byteCount * 2
        if let availableBytes, availableBytes < needed {
            return .notEnoughSpace(neededBytes: needed, availableBytes: availableBytes)
        }
        return nil
    }

    /// Free space for files the person asked for, on the temporary folder's volume.
    static func availableBytes() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
