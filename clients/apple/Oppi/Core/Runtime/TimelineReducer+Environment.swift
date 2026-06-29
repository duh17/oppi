import Foundation
import os.log

private let timelineReducerLoadSessionLog = Logger(
    subsystem: AppIdentifiers.subsystem,
    category: "LoadSession"
)

extension TimelineReducerEnvironment {
    static func app() -> TimelineReducerEnvironment {
        let markdownPrewarmer = MarkdownPrewarmer()
        return TimelineReducerEnvironment(
            markdownPrewarmer: TimelineMarkdownPrewarmer(
                cachePurgeItemThreshold: MarkdownPrewarmer.cachePurgeItemThreshold,
                cancel: {
                    markdownPrewarmer.cancel()
                },
                clearCache: {
                    MarkdownSegmentCache.shared.clearAll()
                },
                prewarm: { assistantTexts in
                    markdownPrewarmer.prewarm(assistantTexts: assistantTexts)
                }
            ),
            logLoadSession: { message in
                timelineReducerLoadSessionLog.info("\(message, privacy: .public)")
            }
        )
    }
}
