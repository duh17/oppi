#if DEBUG
import UIKit

/// The chat-routes server's PDF (`ChatRoutesURLProtocol`), which the
/// `chatRoutes.openPDF` control opens as a tapped file pill does.
/// `CHAT_ROUTES_PDF_FILE=<path>` serves that PDF from the Mac's disk (the
/// simulator shares it): a real document for proof recordings. Otherwise it is
/// a three-page text PDF drawn here.
enum ChatRoutesPDF {
    private static let file = ProcessInfo.processInfo.environment["CHAT_ROUTES_PDF_FILE"]

    /// The served file's name, which the stub matches on; the pill opens it under docs/.
    /// Not `ChatRoutesFixture.pdfName`, the pane harness's PDF.
    static let fileName = file.map { ($0 as NSString).lastPathComponent } ?? "trail-guide.pdf"
    static let path = "docs/" + fileName

    static let data: Data = file.flatMap { FileManager.default.contents(atPath: $0) } ?? text

    private static let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let margin: CGFloat = 72

    /// Paragraphs that fill three Letter pages; page 2 starts with "Water".
    static let pages: [[String]] = [
        [
            "Trail Field Guide",
            "This guide covers the three-day loop from the north trailhead to the lake basin and back. It assumes a party of two to four, light packs, and settled summer weather.",
            "Day one climbs 900 metres over eleven kilometres. Start before eight so the exposed switchbacks are behind you before the afternoon heat. The first reliable water is at the second creek crossing, about six kilometres in.",
            "Camp at the meadow below the pass. The upper sites are flatter but catch the wind after dark; the sites by the stream are sheltered and closer to water.",
        ],
        [
            "Water",
            "Treat all water on this route. The lake outlet runs clear but the basin is grazed through August, and the creeks below the meadow carry runoff from the old mine road.",
            "Carry two litres per person between the pass and the lake. There is no water on the ridge, and the snowfield that used to feed the tarn has been gone by mid-July for the last five seasons.",
            "If the outlet is low, walk ten minutes upstream to the spring on the east shore. It runs year-round and is the coldest water on the loop.",
        ],
        [
            "Weather and turning back",
            "Afternoon storms build over the ridge most days in July. Be off the ridge by one o'clock. If you hear thunder before you reach the pass, wait in the meadow; the descent on the far side has no shelter.",
            "The return leg follows the river and is mostly downhill. Allow five hours from the lake to the trailhead, and longer if the footbridge is out and you have to use the ford.",
        ],
    ]

    private static var text: Data {
        UIGraphicsPDFRenderer(bounds: pageBounds).pdfData { context in
            for page in pages {
                context.beginPage()
                draw(page)
            }
        }
    }

    /// One page: its first paragraph as the heading, the rest as body text.
    private static func draw(_ paragraphs: [String]) {
        let width = pageBounds.width - margin * 2
        var y = margin
        for (index, paragraph) in paragraphs.enumerated() {
            let font = index == 0
                ? UIFont.systemFont(ofSize: 22, weight: .semibold)
                : UIFont.systemFont(ofSize: 13)
            let text = NSAttributedString(string: paragraph, attributes: [.font: font, .foregroundColor: UIColor.black])
            let height = ceil(text.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height)
            text.draw(in: CGRect(x: margin, y: y, width: width, height: height))
            y += height + 14
        }
    }
}
#endif
