import Foundation
import Testing
import UIKit
@testable import Oppi

@Suite("SQL Highlight Debug")
struct SQLHighlightDebugTests {
    @Test("SQL detect returns sql")
    func sqlDetect() {
        #expect(SyntaxLanguage.detect("sql") == .sql)
        #expect(SyntaxLanguage.detect("SQL") == .sql)
    }

    @Test("SQL SELECT highlights keywords differently from identifiers")
    func sqlSelectHighlights() {
        let sql = """
        SELECT CAST(ts_ms / 1000 AS INTEGER) AS time, value
        FROM chat_metric_samples
        WHERE metric = 'chat.catchup_ms'
        """
        let result = SyntaxHighlighter.highlight(sql, language: .sql)
        let ns = result.string as NSString

        let selectRange = ns.range(of: "SELECT")
        #expect(selectRange.location != NSNotFound)

        let selectAttrs = result.attributes(at: selectRange.location, effectiveRange: nil)
        let selectColor = selectAttrs[.foregroundColor] as? UIColor

        let valueRange = ns.range(of: "value")
        #expect(valueRange.location != NSNotFound)
        let valueAttrs = result.attributes(at: valueRange.location, effectiveRange: nil)
        let valueColor = valueAttrs[.foregroundColor] as? UIColor

        #expect(
            selectColor != valueColor,
            "Keyword 'SELECT' (\(String(describing: selectColor))) should differ from identifier 'value' (\(String(describing: valueColor)))"
        )
    }

    @Test("SQL comment detected")
    func sqlComment() {
        let sql = "-- this is a comment\nSELECT 1"
        let result = SyntaxHighlighter.highlight(sql, language: .sql)
        let ns = result.string as NSString

        // The comment text should have comment color
        let commentRange = ns.range(of: "-- this is a comment")
        #expect(commentRange.location != NSNotFound)
        let attrs = result.attributes(at: commentRange.location, effectiveRange: nil)
        let commentColor = attrs[.foregroundColor] as? UIColor

        // SELECT should have keyword color (different from comment)
        let selectRange = ns.range(of: "SELECT")
        let selectAttrs = result.attributes(at: selectRange.location, effectiveRange: nil)
        let selectColor = selectAttrs[.foregroundColor] as? UIColor

        #expect(commentColor != selectColor, "Comment and keyword should have different colors")
    }

    @Test("SQL string literal detected")
    func sqlString() {
        let sql = "WHERE x = 'hello world'"
        let result = SyntaxHighlighter.highlight(sql, language: .sql)
        let ns = result.string as NSString

        let strRange = ns.range(of: "'hello world'")
        #expect(strRange.location != NSNotFound)
        let attrs = result.attributes(at: strRange.location, effectiveRange: nil)
        let stringColor = attrs[.foregroundColor] as? UIColor

        let whereRange = ns.range(of: "WHERE")
        let whereAttrs = result.attributes(at: whereRange.location, effectiveRange: nil)
        let keywordColor = whereAttrs[.foregroundColor] as? UIColor

        #expect(stringColor != keywordColor, "String and keyword should have different colors")
    }
}
