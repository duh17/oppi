// MARK: - Syntax Keyword Sets

/// Keyword sets for languages that still use `SyntaxTokenScanner`.
/// Tree-sitter languages keep empty `SyntaxLanguage.keywords`.

let swiftKeywords: Set<String> = [
    "import", "func", "let", "var", "if", "else", "guard", "return",
    "struct", "class", "enum", "protocol", "extension", "private",
    "public", "internal", "static", "final", "self", "Self", "nil",
    "true", "false", "switch", "case", "default", "for", "while",
    "in", "throws", "async", "await", "some", "any", "typealias",
    "init", "deinit", "override", "mutating", "weak", "try",
    "catch", "throw", "do", "break", "continue", "where",
]

let sqlKeywords: Set<String> = [
    "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES",
    "UPDATE", "SET", "DELETE", "CREATE", "TABLE", "ALTER",
    "DROP", "JOIN", "LEFT", "RIGHT", "INNER", "ON", "AND",
    "OR", "NOT", "NULL", "IS", "IN", "ORDER", "BY", "GROUP",
    "HAVING", "LIMIT", "AS", "DISTINCT", "CASE", "WHEN",
    "THEN", "ELSE", "END",
    "select", "from", "where", "insert", "into", "values",
    "update", "set", "delete", "create", "table", "alter",
    "drop", "join", "on", "and", "or", "not", "null", "is",
    "in", "order", "by", "group", "having", "limit", "as",
    "distinct", "case", "when", "then", "else", "end",
]

let kotlinKeywords: Set<String> = [
    "fun", "val", "var", "if", "else", "when", "for", "while",
    "return", "class", "interface", "object", "enum", "data",
    "sealed", "abstract", "open", "override", "private",
    "public", "internal", "import", "package", "this", "super",
    "null", "true", "false", "is", "as", "in", "throw", "try",
    "catch", "finally", "suspend",
]

let zigKeywords: Set<String> = [
    "const", "var", "fn", "pub", "return", "if", "else", "while",
    "for", "switch", "break", "continue", "struct", "enum", "union",
    "error", "try", "catch", "defer", "errdefer", "comptime",
    "inline", "export", "extern", "test", "unreachable", "undefined",
    "null", "true", "false", "orelse", "and", "or", "async", "await",
    "import", "usingnamespace", "threadlocal", "volatile",
]

let protobufKeywords: Set<String> = [
    "syntax", "package", "import", "option", "message", "enum",
    "service", "rpc", "returns", "oneof", "map", "reserved",
    "repeated", "optional", "required", "extend", "extensions",
    "to", "max", "true", "false", "public", "weak",
    "double", "float", "int32", "int64", "uint32", "uint64",
    "sint32", "sint64", "fixed32", "fixed64", "sfixed32", "sfixed64",
    "bool", "string", "bytes",
]

let graphqlKeywords: Set<String> = [
    "type", "query", "mutation", "subscription", "input", "interface",
    "union", "enum", "scalar", "schema", "extend", "implements",
    "directive", "fragment", "on", "true", "false", "null",
    "repeatable",
]

// MARK: - Document Renderer Languages

let latexKeywords: Set<String> = [
    "begin", "end", "frac", "sqrt", "sum", "prod", "int",
    "left", "right", "text", "mathrm", "mathbf", "mathbb",
    "mathcal", "mathfrak", "overline", "underline", "hat",
    "bar", "vec", "dot", "tilde", "overbrace", "underbrace",
    "alpha", "beta", "gamma", "delta", "epsilon", "theta",
    "lambda", "mu", "pi", "sigma", "omega", "infty",
    "partial", "nabla", "forall", "exists", "in", "notin",
    "subset", "supset", "cup", "cap", "leq", "geq", "neq",
    "approx", "equiv", "times", "div", "cdot", "pm",
    "lim", "sin", "cos", "tan", "log", "ln", "exp",
    "documentclass", "usepackage", "newcommand", "renewcommand",
    "section", "subsection", "label", "ref", "cite",
    "item", "caption", "includegraphics", "input",
]

let orgModeKeywords: Set<String> = [
    "TODO", "DONE", "NEXT", "WAITING", "CANCELLED", "HOLD",
    "DEADLINE", "SCHEDULED", "CLOSED", "CLOCK",
    "PROPERTIES", "END",
    "TITLE", "AUTHOR", "DATE", "OPTIONS", "STARTUP",
    "CATEGORY", "TAGS", "FILETAGS", "ARCHIVE",
    "begin_src", "end_src", "begin_quote", "end_quote",
    "begin_example", "end_example", "begin_export", "end_export",
    "begin_center", "end_center", "begin_verse", "end_verse",
    "RESULTS", "CALL", "NAME", "HEADER",
    "CAPTION", "ATTR_HTML", "ATTR_LATEX",
]

let mermaidKeywords: Set<String> = [
    "flowchart", "graph", "sequenceDiagram", "classDiagram",
    "stateDiagram", "stateDiagram-v2", "erDiagram",
    "gantt", "pie", "gitgraph", "mindmap", "timeline",
    "subgraph", "end", "participant", "actor",
    "activate", "deactivate", "loop", "alt", "else", "opt",
    "par", "critical", "break", "rect", "note",
    "class", "direction", "style", "classDef",
    "click", "link", "callback",
    "TB", "TD", "BT", "RL", "LR",
]

let dotKeywords: Set<String> = [
    "graph", "digraph", "subgraph", "strict",
    "node", "edge",
    "label", "shape", "style", "color", "fillcolor",
    "fontname", "fontsize", "fontcolor",
    "rankdir", "rank", "nodesep", "ranksep",
    "arrowhead", "arrowtail", "dir",
    "weight", "constraint", "penwidth",
    "same", "min", "max", "source", "sink",
    "box", "circle", "ellipse", "diamond", "record",
    "plaintext", "point", "doublecircle", "tripleoctagon",
    "solid", "dashed", "dotted", "bold", "invis", "filled",
]

// MARK: - Godot

let gdscriptKeywords: Set<String> = [
    "func", "var", "const", "class", "class_name", "extends", "signal",
    "enum", "static", "if", "elif", "else", "for", "while", "match",
    "when", "return", "await", "yield", "preload", "load", "self", "super",
    "and", "or", "not", "in", "is", "as", "true", "false", "null",
    "pass", "break", "continue", "breakpoint", "assert",
    // Godot 3 spellings of today's `@onready`, `@export`, and `@tool`.
    "onready", "export", "tool",
    "PI", "TAU", "INF", "NAN",
]

let gdscriptTypeNames: Set<String> = [
    "int", "float", "bool", "void",
]

/// Literal words in Godot's text resource values (`VariantParser`).
let godotResourceKeywords: Set<String> = [
    "true", "false", "null", "nil", "inf", "inf_neg", "nan",
]

let gdshaderKeywords: Set<String> = [
    "shader_type", "render_mode", "stencil_mode", "uniform", "varying",
    "const", "global", "instance", "group_uniforms", "struct",
    "in", "out", "inout", "flat", "smooth",
    "lowp", "mediump", "highp", "precision",
    "if", "else", "for", "while", "do", "switch", "case", "default",
    "break", "continue", "return", "discard", "true", "false",
    "spatial", "canvas_item", "particles", "sky", "fog",
    "source_color", "hint_range", "hint_normal", "hint_default_white",
    "hint_default_black", "hint_enum", "filter_linear", "filter_nearest",
    "repeat_enable", "repeat_disable", "instance_index",
    "hint_screen_texture", "hint_depth_texture", "hint_normal_roughness_texture",
]

let gdshaderTypeNames: Set<String> = [
    "void", "bool", "bvec2", "bvec3", "bvec4",
    "int", "ivec2", "ivec3", "ivec4", "uint", "uvec2", "uvec3", "uvec4",
    "float", "vec2", "vec3", "vec4", "mat2", "mat3", "mat4",
    "sampler2D", "isampler2D", "usampler2D",
    "sampler2DArray", "isampler2DArray", "usampler2DArray",
    "sampler3D", "isampler3D", "usampler3D",
    "samplerCube", "samplerCubeArray", "samplerExternalOES",
]
