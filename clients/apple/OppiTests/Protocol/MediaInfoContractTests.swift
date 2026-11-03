import Foundation
import Testing
@testable import Oppi

/// `protocol/media-info.json`: the shapes `GET /files/current/media-info`
/// answers. Server `media-info-fixtures.test.ts` holds the committed bytes to
/// the protocol type; this side has to decode every example with every field
/// optional.
@Suite("MediaInfo contract")
struct MediaInfoContractTests {
    struct Fixture: Decodable {
        struct Example: Decodable {
            let name: String
            let body: MediaInfo
        }

        let examples: [Example]
    }

    static func fixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: ProtocolFixtures.data("media-info.json"))
    }

    static func example(_ name: String) throws -> MediaInfo {
        let fixture = try fixture()
        return try #require(fixture.examples.first { $0.name == name }).body
    }

    @Test func decodesEveryCommittedExample() throws {
        let fixture = try Self.fixture()
        #expect(fixture.examples.count >= 4)
        // Every field is optional: the unknown-file answer decodes to nothing known.
        let unknown = try Self.example("unknown, as an unparsed or malformed file answers")
        #expect(unknown == MediaInfo(durationSeconds: nil, format: nil, tags: nil))
    }

    @Test func readsTheFormat() throws {
        let body = try Self.example("every field")
        #expect(body.durationSeconds == 2712.4)
        let format = try #require(body.format)
        #expect(format.codec == "aac")
        #expect(format.sampleRate == 44_100)
        #expect(format.channels == 2)
        #expect(format.bitrate == 128_000)
    }

    @Test func readsTheTags() throws {
        let body = try Self.example("every field")
        let tags = try #require(body.tags)
        #expect(tags.title == "Episode 12")
        #expect(tags.artist == "Alex Rivera")
        #expect(tags.album == "Field Notes")
    }

    @Test func treatsAbsentKeysAsUnknown() throws {
        let body = try Self.example("length only, as a header states no format")
        #expect(body.durationSeconds == 12.25)
        #expect(body.format == nil)
        #expect(body.tags == nil)
    }

    @Test func ignoresKeysANewerServerAdds() throws {
        // Chapters and artwork are later slices; an app built before them decodes
        // a server that already sends them instead of failing the whole body.
        let json = """
        {
            "durationSeconds": 2712.4,
            "format": { "codec": "aac", "sampleRate": 44100, "channels": 2, "bitrate": 128000, "profile": "lc" },
            "tags": { "title": "Episode 12", "artist": "Alex Rivera", "album": "Field Notes", "genre": "Speech" },
            "chapters": [{ "startSeconds": 0, "title": "Intro" }],
            "artwork": { "mimeType": "image/jpeg", "width": 1400, "height": 1400, "byteLength": 182344 }
        }
        """
        let body = try JSONDecoder().decode(MediaInfo.self, from: Data(json.utf8))
        #expect(body.durationSeconds == 2712.4)
        #expect(body.format?.codec == "aac")
        #expect(body.tags?.title == "Episode 12")
    }

    @Test func decodesAFormatWithoutNumbers() throws {
        // A container that names its codec and states no usable numbers.
        let body = try JSONDecoder().decode(MediaInfo.self, from: Data(#"{"format":{"codec":"pcm"}}"#.utf8))
        let format = try #require(body.format)
        #expect(format.codec == "pcm")
        #expect(format.sampleRate == nil)
        #expect(format.channels == nil)
        #expect(format.bitrate == nil)
        #expect(body.durationSeconds == nil)
        #expect(body.tags == nil)
    }
}
