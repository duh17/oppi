import Foundation

/// Whether this device has room for a file the app downloads from the server,
/// for Share, Save to Files, or Quick Look. The download goes to disk, never
/// into memory, and resumes after a dropped connection, so neither the app's
/// footprint nor the link's speed limits its size: only free space does.
enum FileDownloadBudget {
    /// Why a download does not start, or stops: the device has
    /// `availableBytes` free and the download needs `neededBytes`.
    struct Refusal: Equatable {
        let neededBytes: Int64
        let availableBytes: Int64

        var title: String { String(localized: "Not Enough Storage") }

        func message(fileName: String) -> String {
            let neededText = ByteCountFormatter.string(fromByteCount: neededBytes, countStyle: .file)
            let availableText = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
            return String(localized: "“\(fileName)” needs \(neededText) free on this device, and \(availableText) is free.")
        }
    }

    /// The refusal for a file of `byteCount` bytes on a device with
    /// `availableBytes` free, or nil when it may download. Nil sizes are not
    /// known and pass. The download needs room for itself and for the copy
    /// that Save to Files or a receiving app makes of it.
    static func refusal(byteCount: Int64?, availableBytes: Int64?) -> Refusal? {
        guard let byteCount, let availableBytes else { return nil }
        let needed = byteCount * 2
        guard availableBytes < needed else { return nil }
        return Refusal(neededBytes: needed, availableBytes: availableBytes)
    }

    /// Free space for files the person asked for, on the temporary folder's volume.
    static func availableBytes() -> Int64? {
        let values = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
