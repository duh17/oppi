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

@Suite("VideoExtractor")
struct VideoExtractorTests {

    @Test func extractDataURI() {
        let text = "Here is video: data:video/mp4;base64,AAAAHGZ0eXBtcDQ= done."
        let videos = VideoExtractor.extract(from: text)
        #expect(videos.count == 1)
        #expect(videos[0].mimeType == "video/mp4")
        #expect(videos[0].base64 == "AAAAHGZ0eXBtcDQ=")
    }

    @Test func extractMultipleDataURIs() {
        let text = "data:video/mp4;base64,AAAA data:video/webm;base64,BBBB"
        let videos = VideoExtractor.extract(from: text)
        #expect(videos.count == 2)
        #expect(videos[0].mimeType == "video/mp4")
        #expect(videos[1].mimeType == "video/webm")
    }

    @Test func dataURIWithNewlines() {
        let text = "data:video/mp4;base64,AAAAHGZ0\neXBtcDQ="
        let videos = VideoExtractor.extract(from: text)
        #expect(videos.count == 1)
        #expect(!videos[0].base64.contains("\n"))
    }

    @Test func malformedDataURIIgnored() {
        let text = "data:text/plain;base64,SGVsbG8="
        let videos = VideoExtractor.extract(from: text)
        #expect(videos.isEmpty)
    }
}

@Suite("MediaMimeType")
struct MediaMimeTypeTests {

    @Test func preservesSourceVideoExtensionWhenMimeTypeUnknown() {
        #expect(MediaMimeType.preferredFileExtension(forVideo: nil, fallbackPathExtension: "mkv") == "mkv")
    }

    @Test func preservesSourceAudioExtensionWhenMimeTypeUnknown() {
        #expect(MediaMimeType.preferredFileExtension(forAudio: nil, fallbackPathExtension: ".oga") == "oga")
    }

    @Test func fallsBackToKnownMimeTypeWhenExtensionMissing() {
        #expect(MediaMimeType.preferredFileExtension(forVideo: "video/quicktime") == "mov")
        #expect(MediaMimeType.preferredFileExtension(forAudio: "audio/flac") == "flac")
    }

    @Test func recognizesAdditionalMediaExtensions() {
        #expect(MediaMimeType.videoMimeType(forPathExtension: "mkv") == "video/x-matroska")
        #expect(MediaMimeType.videoMimeType(forPathExtension: "ogv") == "video/ogg")
        #expect(MediaMimeType.audioMimeType(forPathExtension: "oga") == "audio/ogg")
        #expect(MediaMimeType.audioMimeType(forPathExtension: "aifc") == "audio/aiff")
    }
}
