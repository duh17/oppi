import Foundation
import Testing
@testable import Oppi

@Suite("Godot Highlighting")
struct GodotHighlightingTests {

    /// Token texts of one kind, in source order.
    private func texts(_ kind: SyntaxTokenKind, in code: String, language: SyntaxLanguage) -> [String] {
        let source = code as NSString
        return SyntaxHighlighter.scanTokenRanges(code, language: language)
            .filter { $0.kind == kind }
            .map { source.substring(with: NSRange(location: $0.location, length: $0.length)) }
    }

    @Test func detectsGodotExtensionsAndFences() {
        #expect(SyntaxLanguage.detect("gd") == .gdscript)
        #expect(SyntaxLanguage.detect("gdscript") == .gdscript)
        #expect(SyntaxLanguage.detect("GDScript") == .gdscript)
        for ext in ["tscn", "tres", "godot", "import", "gdresource"] {
            #expect(SyntaxLanguage.detect(ext) == .godotResource, "\(ext)")
        }
        #expect(SyntaxLanguage.detect("gdshader") == .gdshader)
        #expect(SyntaxLanguage.detect("gdshaderinc") == .gdshader)
        // Only Godot's own export_presets.cfg is a Godot resource; other .cfg files stay plain.
        #expect(SyntaxLanguage.detect("cfg") == .unknown)
        #expect(FileKind.detect(from: "setup.cfg") == .plain)
    }

    // A representative script, like a sound-effects node in a game project.
    private let sfx = """
    ## Procedural sound effects for the sword lab.
    class_name Sfx
    extends Node

    signal played(name: StringName)

    const SAMPLE_RATE := 44100.0
    @export var volume_db: float = -6.0
    @onready var _player: AudioStreamPlayer = $Audio/Player

    func play_swing(pitch := 1.0) -> void:
    \tvar stream := AudioStreamGenerator.new()
    \tif not _player.playing:
    \t\t_player.play() # start lazily
    \tplayed.emit(&"swing")
    \tvar path := ^"Audio/Player"
    \tfor i in range(0x10):
    \t\tawait get_tree().process_frame
    \treturn
    """

    @Test func gdscriptTokens() {
        let keywords = texts(.keyword, in: sfx, language: .gdscript)
        for word in ["class_name", "extends", "signal", "const", "var", "func", "if", "not", "for", "in", "await", "return"] {
            #expect(keywords.contains(word), "\(word) should be a keyword")
        }
        #expect(!keywords.contains("play_swing"))

        let types = texts(.type, in: sfx, language: .gdscript)
        for word in ["Sfx", "Node", "StringName", "float", "AudioStreamPlayer", "void", "AudioStreamGenerator", "@export", "@onready"] {
            #expect(types.contains(word), "\(word) should be a type")
        }
        #expect(!types.contains("SAMPLE_RATE"), "an all-caps constant is not a type")

        #expect(texts(.comment, in: sfx, language: .gdscript) == [
            "## Procedural sound effects for the sword lab.",
            "# start lazily",
        ])
        #expect(texts(.string, in: sfx, language: .gdscript) == ["$Audio/Player", "&\"swing\"", "^\"Audio/Player\""])
        #expect(texts(.number, in: sfx, language: .gdscript) == ["44100.0", "6.0", "1.0", "0x10"])
        #expect(texts(.operator, in: sfx, language: .gdscript) == [":=", ":=", ":=", ":="])
    }

    @Test func gdscriptBytePathMatchesCharacterPath() {
        // The ASCII byte scanner and the character scanner are parallel copies.
        let byChars = SyntaxTokenScanner.scanTokenRanges(sfx, language: .gdscript)
        let byBytes = SyntaxTokenScanner.scanTokenRangesUTF8(sfx, language: .gdscript)
        #expect(byChars == byBytes)

        // Non-ASCII text takes the character path; offsets stay UTF-16.
        let accented = "var café := $\"Héros\" # ✓"
        let source = accented as NSString
        let ranges = SyntaxTokenScanner.scanTokenRangesUTF8(accented, language: .gdscript)
        let pairs = ranges.map { (source.substring(with: NSRange(location: $0.location, length: $0.length)), $0.kind) }
        #expect(pairs.map(\.0) == ["var", ":=", "$\"Héros\"", "# ✓"])
        #expect(pairs.map(\.1) == [.keyword, .operator, .string, .comment])
    }

    @Test func gdscriptFencePaintsInMarkdownSource() {
        let markdown = "```gdscript\nfunc _ready() -> void:\n\tpass\n```\n" as NSString
        let spans = MarkdownSourceHighlighter.spans(in: markdown, window: NSRange(location: 0, length: markdown.length))
        let keywordTexts = spans.filter { $0.style == .token(.keyword) }
            .map { markdown.substring(with: NSRange(location: $0.location, length: $0.length)) }
        #expect(keywordTexts == ["func", "pass"])
    }

    @Test func godotSceneTokens() {
        let scene = """
        [gd_scene load_steps=3 format=3 uid="uid://b6x8k2"]

        [ext_resource type="Script" path="res://sfx.gd" id="1_abc"]

        ; Player root
        [node name="Player" type="CharacterBody2D"]
        script = ExtResource("1_abc")
        position = Vector2(64, -12.5)
        metadata/_edit_lock_ = true
        ui_jump={
        "deadzone": 0.5,
        "events": [Object(InputEventKey,"keycode":32)]
        }
        text = "first
        second"
        """
        #expect(texts(.keyword, in: scene, language: .godotResource) == ["gd_scene", "ext_resource", "node", "true"])
        #expect(texts(.type, in: scene, language: .godotResource) == [
            "load_steps", "format", "uid",
            "type", "path", "id",
            "name", "type",
            "script", "ExtResource",
            "position", "Vector2",
            "metadata/_edit_lock_",
            "ui_jump", "Object", "InputEventKey",
            "text",
        ])
        #expect(texts(.comment, in: scene, language: .godotResource) == ["; Player root"])
        #expect(texts(.number, in: scene, language: .godotResource) == ["3", "3", "64", "-12.5", "0.5", "32"])
        let strings = texts(.string, in: scene, language: .godotResource)
        #expect(strings.contains("\"deadzone\""), "a line inside a value is not a key")
        #expect(strings.contains("\"first\nsecond\""), "a string may span lines")
        #expect(strings.count == 11)
    }

    @Test func godotShaderTokens() {
        let shader = """
        shader_type canvas_item;
        render_mode unshaded;
        #include "res://common.gdshaderinc"

        // Tint toward a color over time.
        uniform vec4 tint : source_color = vec4(1.0, 0.5, 0.0, 1.0);
        uniform sampler2DArray noise : hint_default_white;
        varying vec2 world_uv;

        /* fragment stage */
        void fragment() {
        \tfloat t = sin(TIME * 2.0);
        \tCOLOR = mix(texture(TEXTURE, UV), tint, t);
        }
        """
        let keywords = texts(.keyword, in: shader, language: .gdshader)
        for word in ["shader_type", "canvas_item", "render_mode", "uniform", "source_color", "hint_default_white", "varying"] {
            #expect(keywords.contains(word), "\(word) should be a keyword")
        }
        #expect(keywords.contains("#include \"res://common.gdshaderinc\""), "#include is a directive line")
        #expect(texts(.type, in: shader, language: .gdshader) == [
            "vec4", "vec4", "sampler2DArray", "vec2", "void", "float",
        ])
        #expect(texts(.comment, in: shader, language: .gdshader) == [
            "// Tint toward a color over time.",
            "/* fragment stage */",
        ])
        #expect(texts(.number, in: shader, language: .gdshader) == ["1.0", "0.5", "0.0", "1.0", "2.0"])
    }
}
