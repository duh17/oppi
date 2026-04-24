import Foundation
import Testing
@testable import Oppi

@Suite("ImageExtractor")
struct ImageExtractorTests {

    @Test func extractDataURI() {
        let text = "Here is an image: data:image/png;base64,iVBORw0KGgoAAAANSUhEUg== done."
        let images = ImageExtractor.extract(from: text)
        #expect(images.count == 1)
        #expect(images[0].mimeType == "image/png")
        #expect(images[0].base64 == "iVBORw0KGgoAAAANSUhEUg==")
    }

    @Test func extractMultipleDataURIs() {
        let text = """
        data:image/png;base64,AAAA data:image/jpeg;base64,BBBB
        """
        let images = ImageExtractor.extract(from: text)
        #expect(images.count == 2)
        #expect(images[0].mimeType == "image/png")
        #expect(images[1].mimeType == "image/jpeg")
    }

    @Test func noImagesInPlainText() {
        let text = "Just some plain text with no images"
        let images = ImageExtractor.extract(from: text)
        #expect(images.isEmpty)
    }

    @Test func malformedDataURIIgnored() {
        let text = "data:text/plain;base64,SGVsbG8="
        let images = ImageExtractor.extract(from: text)
        #expect(images.isEmpty)
    }

    @Test func dataURIWithNewlines() {
        let text = "data:image/gif;base64,R0lGODlh\nAQABAIAAAP///wAAA\nCH5BAEAAA=="
        let images = ImageExtractor.extract(from: text)
        #expect(images.count == 1)
        #expect(!images[0].base64.contains("\n"))
    }
}

@Suite("AudioExtractor")
struct AudioExtractorTests {

    @Test func extractDataURI() {
        let text = "Here is audio: data:audio/wav;base64,UklGRiQAAABXQVZF done."
        let clips = AudioExtractor.extract(from: text)
        #expect(clips.count == 1)
        #expect(clips[0].mimeType == "audio/wav")
        #expect(clips[0].base64 == "UklGRiQAAABXQVZF")
    }

    @Test func extractMultipleDataURIs() {
        let text = "data:audio/mp3;base64,AAAA data:audio/m4a;base64,BBBB"
        let clips = AudioExtractor.extract(from: text)
        #expect(clips.count == 2)
        #expect(clips[0].mimeType == "audio/mp3")
        #expect(clips[1].mimeType == "audio/m4a")
    }

    @Test func malformedDataURIIgnored() {
        let text = "data:text/plain;base64,SGVsbG8="
        let clips = AudioExtractor.extract(from: text)
        #expect(clips.isEmpty)
    }
}

@Suite("MediaMimeType")
struct MediaMimeTypeTests {

    @Test func preservesSourceAudioExtensionWhenMimeTypeUnknown() {
        #expect(MediaMimeType.preferredFileExtension(forAudio: nil, fallbackPathExtension: ".oga") == "oga")
    }

    @Test func fallsBackToKnownMimeTypeWhenExtensionMissing() {
        #expect(MediaMimeType.preferredFileExtension(forAudio: "audio/flac") == "flac")
    }

    @Test func recognizesAdditionalAudioExtensions() {
        #expect(MediaMimeType.audioMimeType(forPathExtension: "oga") == "audio/ogg")
        #expect(MediaMimeType.audioMimeType(forPathExtension: "aifc") == "audio/aiff")
    }

    @Test func detectsSVGDataWithLeadingWhitespaceAndXMLPreamble() {
        let inlineSVG = Data("  \n\t<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        let xmlSVG = Data("<?xml version=\"1.0\"?><svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        let plainXML = Data("<?xml version=\"1.0\"?><note>Hello</note>".utf8)

        #expect(MediaMimeType.isSVGData(inlineSVG))
        #expect(MediaMimeType.isSVGData(xmlSVG))
        #expect(!MediaMimeType.isSVGData(plainXML))
    }

    @Test func extractsSVGAspectRatioFromViewBox() {
        let svg = Data("<svg viewBox=\"0 0 320 180\" xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        let ratio = MediaMimeType.extractSVGViewBoxAspectRatio(svg)
        #expect(ratio != nil)
        #expect(abs((ratio ?? 0) - (320.0 / 180.0)) < 0.0001)
    }
}
