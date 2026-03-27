// MARK: - Syntax Keyword Sets

/// Keyword sets for each supported language. Referenced by `SyntaxLanguage.keywords`
/// and the shell scanner in `SyntaxHighlighter`.

let swiftKeywords: Set<String> = [
    "import", "func", "let", "var", "if", "else", "guard", "return",
    "struct", "class", "enum", "protocol", "extension", "private",
    "public", "internal", "static", "final", "self", "Self", "nil",
    "true", "false", "switch", "case", "default", "for", "while",
    "in", "throws", "async", "await", "some", "any", "typealias",
    "init", "deinit", "override", "mutating", "weak", "try",
    "catch", "throw", "do", "break", "continue", "where",
]

let tsKeywords: Set<String> = [
    "function", "const", "let", "var", "if", "else", "return",
    "import", "export", "from", "class", "interface", "type",
    "enum", "private", "public", "static", "readonly", "this",
    "null", "undefined", "true", "false", "switch", "case",
    "default", "for", "while", "of", "in", "async", "await",
    "throw", "try", "catch", "finally", "new", "typeof",
    "extends", "implements", "super", "as", "declare",
]

let pythonKeywords: Set<String> = [
    "def", "class", "if", "elif", "else", "return", "import",
    "from", "as", "self", "None", "True", "False", "for",
    "while", "in", "with", "try", "except", "finally", "raise",
    "pass", "lambda", "yield", "async", "await", "not", "and",
    "or", "is", "del", "global", "assert", "break", "continue",
]

let goKeywords: Set<String> = [
    "func", "var", "const", "if", "else", "return", "import",
    "package", "struct", "interface", "type", "for", "range",
    "switch", "case", "default", "go", "chan", "defer", "nil",
    "true", "false", "map", "make", "select", "break",
    "continue", "fallthrough",
]

let rustKeywords: Set<String> = [
    "fn", "let", "mut", "if", "else", "return", "use", "mod",
    "struct", "enum", "impl", "trait", "pub", "self", "Self",
    "match", "for", "while", "in", "loop", "async", "await",
    "true", "false", "where", "type", "const", "static",
    "ref", "move", "unsafe", "crate", "super", "as", "dyn",
]

let rubyKeywords: Set<String> = [
    "def", "class", "module", "if", "elsif", "else", "unless",
    "return", "require", "include", "end", "do", "begin",
    "rescue", "ensure", "raise", "yield", "self", "nil",
    "true", "false", "and", "or", "not", "while", "until",
    "for", "in", "case", "when",
]

let shellKeywords: Set<String> = [
    "if", "then", "else", "elif", "fi", "for", "do", "done",
    "while", "until", "case", "esac", "function", "return",
    "exit", "export", "local", "source", "echo", "set",
    "unset", "true", "false",
]

let shellCommandStarterKeywords: Set<String> = [
    "if", "then", "elif", "else", "do", "while", "until", "case",
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

let cKeywords: Set<String> = [
    "if", "else", "for", "while", "do", "switch", "case",
    "default", "return", "break", "continue", "struct",
    "enum", "union", "typedef", "const", "static", "extern",
    "void", "int", "char", "float", "double", "long", "short",
    "unsigned", "sizeof", "NULL", "true", "false", "include",
    "define", "ifdef", "ifndef", "endif",
    "class", "public", "private", "protected", "virtual",
    "override", "namespace", "using", "template", "auto",
    "nullptr", "new", "delete", "this", "throw", "try", "catch",
]

let javaKeywords: Set<String> = [
    "class", "interface", "enum", "abstract", "extends",
    "implements", "public", "private", "protected", "static",
    "final", "void", "int", "long", "double", "float",
    "boolean", "String", "if", "else", "for", "while",
    "switch", "case", "default", "return", "break", "new",
    "this", "super", "null", "true", "false", "try", "catch",
    "finally", "throw", "import", "package", "instanceof",
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
