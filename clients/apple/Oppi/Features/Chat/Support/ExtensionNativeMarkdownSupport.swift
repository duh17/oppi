import Foundation

enum ExtensionNativeMarkdownSupport {
    static func rewrittenMarkdown(
        _ markdown: String,
        serverID: String?,
        workspaceID: String?,
        sessionID: String?,
        sourceDirectory: String?
    ) -> String {
        let rewritten = MarkdownWikiLinkRewriter.rewrite(
            blocks: parseCommonMark(markdown),
            serverID: serverID,
            workspaceID: workspaceID,
            sessionID: sessionID,
            sourceDirectory: sourceDirectory
        )
        return MarkdownBlockSerializer.serialize(rewritten)
    }
}
