import Foundation
import Testing
@testable import Oppi

@Suite("File download budget")
struct FileDownloadBudgetTests {
    @Test func aLargeFileDownloadsWhenTheDeviceHasRoom() {
        let size: Int64 = 50_000_000_000
        #expect(FileDownloadBudget.refusal(byteCount: size, availableBytes: size * 2) == nil)
    }

    @Test func needsRoomForTheDownloadAndOneCopyOfIt() {
        let size: Int64 = 300_000_000
        #expect(FileDownloadBudget.refusal(byteCount: size, availableBytes: size * 2) == nil)
        #expect(
            FileDownloadBudget.refusal(byteCount: size, availableBytes: size * 2 - 1)
                == FileDownloadBudget.Refusal(neededBytes: size * 2, availableBytes: size * 2 - 1)
        )
    }

    @Test func anUnknownSizeOrFreeSpaceStarts() {
        #expect(FileDownloadBudget.refusal(byteCount: nil, availableBytes: 0) == nil)
        #expect(FileDownloadBudget.refusal(byteCount: .max / 4, availableBytes: nil) == nil)
    }
}

@Suite("File download failure words")
struct FileDownloadFailureTests {
    @Test func aCancelSaysNothing() {
        #expect(FileDownloadFailure(CancellationError()) == nil)
        #expect(FileDownloadFailure(URLError(.cancelled)) == nil)
    }

    @Test func eachRefusalNamesItsCause() {
        #expect(FileDownloadFailure(FileDownloadError.rejected(status: 404, message: "File not found"))?.kind == .notFound)
        #expect(
            FileDownloadFailure(FileDownloadError.rejected(status: 403, message: "Path outside sandbox workspace"))?.kind
                == .refused(reason: "Path outside sandbox workspace")
        )
        #expect(
            FileDownloadFailure(FileDownloadError.rejected(status: 413, message: "File too large (max 100MB)"))?.kind
                == .tooLarge(reason: "File too large (max 100MB)")
        )
        #expect(FileDownloadFailure(FileDownloadError.rejected(status: 401, message: nil))?.kind == .notSignedIn)
        #expect(
            FileDownloadFailure(FileDownloadError.rejected(status: 500, message: "Failed to read file"))?.kind
                == .serverError(status: 500, reason: "Failed to read file")
        )
        #expect(FileDownloadFailure(FileDownloadError.digestMismatch)?.kind == .changedInTransfer)
    }

    @Test func tellsOfflineFromAnUnreachableServer() {
        #expect(FileDownloadFailure(URLError(.notConnectedToInternet))?.kind == .offline)
        #expect(FileDownloadFailure(URLError(.dataNotAllowed))?.kind == .offline)
        for code: URLError.Code in [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost] {
            #expect(FileDownloadFailure(URLError(code))?.kind == .serverUnreachable, "\(code)")
        }
        #expect(FileDownloadFailure(CocoaError(.fileWriteOutOfSpace))?.kind == .outOfSpace)
    }

    @Test func theMessageNamesTheFileAndTheServersReason() {
        let refused = FileDownloadFailure(FileDownloadError.rejected(status: 403, message: "Path outside sandbox workspace"))
        #expect(refused?.title == "Can't Download This File")
        #expect(refused?.message(fileName: "clip.mov") == "The server won't send “clip.mov”: Path outside sandbox workspace.")
        let gone = FileDownloadFailure(FileDownloadError.rejected(status: 404, message: nil))
        #expect(gone?.message(fileName: "clip.mov").contains("“clip.mov” is no longer on the server") == true)
    }
}

@Suite("File download progress words")
@MainActor
struct FileShareProgressOverlayTests {
    @Test func showsHowMuchArrivedAndWhenItIsReconnecting() {
        let half = FileDownloadProgress(received: 400_000_000, expected: 800_000_000)
        #expect(FileShareProgressOverlay.statusText(half) == "400 MB of 800 MB")
        let dropped = FileDownloadProgress(received: 400_000_000, expected: 800_000_000, reconnecting: true)
        #expect(FileShareProgressOverlay.statusText(dropped) == "Connection lost. Reconnecting… 400 MB of 800 MB")
        #expect(FileShareProgressOverlay.statusText(FileDownloadProgress(received: 1_000, expected: nil)) == "1 KB")
    }
}
