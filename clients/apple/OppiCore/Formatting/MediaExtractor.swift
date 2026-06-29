import Foundation

/// Extract base64 image data from tool output text.
///
/// Detects `data:image/<type>;base64,<data>` data URIs.
struct ImageExtractor {
    struct ExtractedImage: Identifiable, Sendable {
        let id = UUID()
        let base64: String
        let mimeType: String?
        let range: Range<String.Index>
    }

    static func extract(from text: String) -> [ExtractedImage] {
        var images: [ExtractedImage] = []

        // Use alternation so newlines within base64 are captured but a newline
        // followed by `data:` (start of the next URI) stops the match. Without
        // this, the greedy `[\n\r]` eats into the next data URI when trace text
        // joins multiple images with `\n`.
        let dataUriPattern = /data:image\/([a-zA-Z0-9+.-]+);base64,((?:[A-Za-z0-9+\/=]|[\r\n](?!data:))+)/
        for match in text.matches(of: dataUriPattern) {
            let mimeType = "image/" + String(match.output.1)
            let base64 = String(match.output.2)
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            images.append(ExtractedImage(
                base64: base64,
                mimeType: mimeType,
                range: match.range
            ))
        }

        return images
    }
}

/// Extract base64 audio data from tool output text.
///
/// Detects `data:audio/<type>;base64,<data>` data URIs.
struct AudioExtractor {
    struct ExtractedAudio: Identifiable, Sendable {
        let id = UUID()
        let base64: String
        let mimeType: String?
        let range: Range<String.Index>
    }

    static func extract(from text: String) -> [ExtractedAudio] {
        var audio: [ExtractedAudio] = []

        // Same boundary-safe alternation as ImageExtractor — prevent greedy
        // over-matching across newline-separated data URIs.
        let dataUriPattern = /data:audio\/([a-zA-Z0-9+.-]+);base64,((?:[A-Za-z0-9+\/=]|[\r\n](?!data:))+)/
        for match in text.matches(of: dataUriPattern) {
            let mimeType = "audio/" + String(match.output.1)
            let base64 = String(match.output.2)
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\r", with: "")
            audio.append(ExtractedAudio(
                base64: base64,
                mimeType: mimeType,
                range: match.range
            ))
        }

        return audio
    }
}
