import Testing
import UIKit
@testable import Oppi

/// Pasted and captured images are encoded off the main actor. The batch lands
/// in the draft once, in the order it arrived, and only while the draft that
/// asked for it is still the draft on screen.
@Suite("Composer image batches")
@MainActor
struct ComposerImageBatchTests {
    /// A solid image `side` points square, at scale 1 so `side` is its pixel width.
    private func image(side: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: side, height: side)))
        }
    }

    private func width(of attachment: PendingAttachment) -> Int? {
        guard let encoded = attachment.imageAttachment,
              let data = Data(base64Encoded: encoded.data),
              let decoded = UIImage(data: data) else { return nil }
        return Int(decoded.size.width * decoded.scale)
    }

    /// A draft the helpers read and write like a composer binding does.
    private final class Draft {
        var attachments: [PendingAttachment] = []
        var gateChecks = 0
    }

    @Test func aPastedBatchLandsOnceInTheOrderItArrived() async {
        let draft = Draft()
        // The first image takes far longer to encode than the rest; each
        // finishing on its own would put the small ones ahead of it.
        let sides: [CGFloat] = [3_000, 8, 16, 24]

        ComposerShared.handlePastedImages(
            sides.map(image(side:)),
            getAttachments: { draft.attachments },
            setAttachments: { draft.attachments = $0 },
            shouldAccept: { draft.gateChecks += 1; return true }
        )

        let landed = await waitForMainActorCondition(timeout: .seconds(20)) { draft.attachments.count == sides.count }
        #expect(landed)
        #expect(draft.attachments.compactMap(width(of:)) == sides.map { Int($0) })
        #expect(draft.gateChecks == 1, "one decision for the batch, not one per image")
    }

    @Test func aPastedBatchIsDroppedWhenTheDraftWasSentOrClearedMeanwhile() async {
        let draft = Draft()
        var accepting = true

        ComposerShared.handlePastedImages(
            [image(side: 3_000), image(side: 8)],
            getAttachments: { draft.attachments },
            setAttachments: { draft.attachments = $0 },
            shouldAccept: { draft.gateChecks += 1; return accepting }
        )
        // Send or Clear lands while the encode is still running.
        accepting = false

        let decided = await waitForMainActorCondition(timeout: .seconds(10)) { draft.gateChecks > 0 }
        #expect(decided, "the batch asks before it lands")
        #expect(draft.attachments.isEmpty, "nothing from the old draft leaks into the next one")
    }

    @Test func aCapturedImageIsDroppedWhenTheDraftWasSentOrClearedMeanwhile() async {
        let draft = Draft()
        var accepting = true

        ComposerShared.addCapturedImage(
            image(side: 64),
            getAttachments: { draft.attachments },
            setAttachments: { draft.attachments = $0 },
            shouldAccept: { draft.gateChecks += 1; return accepting }
        )
        accepting = false

        let decided = await waitForMainActorCondition(timeout: .seconds(10)) { draft.gateChecks > 0 }
        #expect(decided, "the capture asks before it lands")
        #expect(draft.attachments.isEmpty)
    }

    @Test func aCapturedImageLandsAfterTheAttachmentsAlreadyInTheDraft() async {
        let draft = Draft()
        draft.attachments = [PendingImage.from(image(side: 8)).pendingAttachment]

        ComposerShared.addCapturedImage(
            image(side: 64),
            getAttachments: { draft.attachments },
            setAttachments: { draft.attachments = $0 },
            shouldAccept: { true }
        )

        #expect(await waitForMainActorCondition(timeout: .seconds(20)) { draft.attachments.count == 2 })
        #expect(draft.attachments.compactMap(width(of:)) == [8, 64])
    }
}
