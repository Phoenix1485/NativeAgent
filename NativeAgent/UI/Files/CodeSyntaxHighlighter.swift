import AppKit

enum CodeSyntaxHighlighter {
    enum Kind: String, CaseIterable, Sendable { case comment, string, keyword, number, type }
    struct Token: Equatable, Sendable {
        let kind: Kind
        let range: NSRange
    }

    /// A lightweight lexer for previews. One expression gives strings and comments
    /// precedence, so comment markers inside a quoted string keep their meaning.
    static func tokens(in text: String, path: String) -> [Token] {
        let ext = (path as NSString).pathExtension.lowercased()
        let name = (path as NSString).lastPathComponent.lowercased()
        let hashComments = ["py", "rb", "sh", "bash", "zsh", "fish", "yaml", "yml", "toml", "r", "pl", "conf", "ini"].contains(ext)
            || ["dockerfile", "makefile", "gemfile"].contains(name)
        let markup = ["html", "htm", "xml", "svg", "vue", "svelte"].contains(ext)
        let sql = ext == "sql"
        let supported = hashComments || markup || sql || ["swift", "js", "jsx", "ts", "tsx", "mjs", "cjs", "json", "jsonc", "css", "scss", "sass", "less", "c", "h", "cc", "cpp", "cxx", "hpp", "m", "mm", "cs", "java", "kt", "kts", "go", "rs", "php", "dart", "lua", "graphql", "gql"].contains(ext)
        guard supported, !text.isEmpty, !Task.isCancelled else { return [] }
        let comment: String
        if markup { comment = #"<!--[\s\S]*?(?:-->|\z)|/\*[\s\S]*?(?:\*/|\z)|//[^\r\n]*"# }
        else if hashComments { comment = #"#[^\r\n]*"# }
        else if sql || ext == "lua" { comment = #"--[^\r\n]*|/\*[\s\S]*?(?:\*/|\z)"# }
        else { comment = #"//[^\r\n]*|/\*[\s\S]*?(?:\*/|\z)"# }
        let string = #"\"\"\"[\s\S]*?(?:\"\"\"|\z)|'''[\s\S]*?(?:'''|\z)|\"(?:\\[\s\S]|[^\"\\\r\n])*\"|'(?:\\[\s\S]|[^'\\\r\n])*'|`(?:\\[\s\S]|[^`\\])*`"#
        let words = "actor as async await associatedtype break case catch class const continue convenience def default defer deinit delete do dynamic else enum export extension false fileprivate final finally for from func function get guard if implements import in init interface internal is lambda lazy let match module mut namespace new nil none null open operator override package private protected protocol public raise readonly repeat required rethrows return select self set some static struct subscript super switch throw throws trait true try type typealias typeof undefined union var virtual void weak when where while with yield SELECT FROM WHERE JOIN LEFT RIGHT INNER OUTER ON AS INSERT INTO UPDATE SET DELETE CREATE TABLE VALUES ORDER BY GROUP LIMIT AND OR NOT NULL def elif except pass True False None"
        let keyword = #"\b(?:"# + words.split(separator: " ").joined(separator: "|") + #")\b"#
        let number = #"\b(?:0[xX][0-9a-fA-F_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b"#
        let type = markup ? #"</?[A-Za-z][\w:.-]*|\b[A-Z][A-Za-z0-9_]*\b"# : #"\b[A-Z][A-Za-z0-9_]*\b"#
        let patterns: [(Kind, String)] = [(.comment, comment), (.string, string), (.keyword, keyword), (.number, number), (.type, type)]
        let combined = patterns.map { "(?<\($0.0.rawValue)>\($0.1))" }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: combined) else { return [] }
        var tokens: [Token] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length)) { result, _, stop in
            guard !Task.isCancelled, tokens.count < 50_000 else { stop.pointee = true; return }
            guard let result else { return }
            for kind in Kind.allCases {
                let range = result.range(withName: kind.rawValue)
                if range.location != NSNotFound { tokens.append(Token(kind: kind, range: range)); break }
            }
        }
        return tokens
    }

    static func color(for kind: Kind) -> NSColor {
        switch kind {
        case .comment: return .secondaryLabelColor
        case .string: return .systemGreen
        case .keyword: return .systemPurple
        case .number: return .systemOrange
        case .type: return .systemTeal
        }
    }
}
