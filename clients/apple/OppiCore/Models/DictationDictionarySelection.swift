import Foundation

/// Selection is not application: SpeechAnalyzer and server STT may ignore these hints.
struct DictationDictionarySelection: Equatable {
    enum Exclusion: Equatable {
        case duplicate, phraseBytes, phraseCount, totalBytes
    }
    struct Entry: Equatable {
        let phrase: String
        let scope: Scope
        let exclusion: Exclusion?
    }
    enum Scope: Equatable { case workspace, global }

    let selected: [String]
    let entries: [Entry]

    static func make(workspace: [String], global: [String]) -> Self {
        var selected: [String] = []
        var entries: [Entry] = []
        var seen = Set<String>()
        var total = 0
        for (scope, phrases) in [(Scope.workspace, workspace), (.global, global)] {
            for phrase in phrases {
                let bytes = phrase.utf8.count
                let reason: Exclusion?
                if seen.contains(phrase) { reason = .duplicate }
                else if bytes > DictationContextualStrings.maxPhraseUTF8Bytes { reason = .phraseBytes }
                else if selected.count >= DictationContextualStrings.maxPhraseCount { reason = .phraseCount }
                else if total + bytes > DictationContextualStrings.maxTotalUTF8Bytes { reason = .totalBytes }
                else { reason = nil }
                seen.insert(phrase)
                entries.append(Entry(phrase: phrase, scope: scope, exclusion: reason))
                if reason == nil {
                    selected.append(phrase)
                    total += bytes
                }
            }
        }
        return Self(selected: selected, entries: entries)
    }
}
