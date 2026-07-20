import Foundation

enum AgentIconValidationError: Equatable, Sendable {
    case empty
    case multipleEmoji
    case tooLong
    case malformed

    var message: String {
        switch self {
        case .empty, .malformed:
            return "Enter one emoji or an SF Symbol name."
        case .multipleEmoji:
            return "Use one Unicode emoji."
        case .tooLong:
            return "Icon names can’t exceed 128 characters."
        }
    }
}

enum AgentIconValue {
    enum Classification: Equatable, Sendable {
        case emoji(String)
        case symbolCandidate(String)
        case invalid(AgentIconValidationError)
    }

    static func classify(_ rawValue: String?) -> Classification {
        guard let rawValue else { return .invalid(.empty) }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .invalid(.empty) }
        guard value.unicodeScalars.count <= 128 else { return .invalid(.tooLong) }

        if value.count == 1,
           let character = value.first,
           isEmoji(character) {
            return .emoji(value)
        }

        if value.unicodeScalars.allSatisfy(isSymbolNameScalar) {
            return .symbolCandidate(value)
        }

        if value.unicodeScalars.contains(where: { $0.properties.isEmoji }) {
            return .invalid(.multipleEmoji)
        }
        return .invalid(.malformed)
    }

    private static func isSymbolNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E:
            return true
        default:
            return false
        }
    }

    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = Array(character.unicodeScalars)
        let keycapBases = Set<UInt32>([0x23, 0x2A] + Array(0x30...0x39))
        if scalars.count == 2,
           keycapBases.contains(scalars[0].value),
           scalars[1].value == 0x20E3 {
            return true
        }
        if scalars.count == 3,
           keycapBases.contains(scalars[0].value),
           scalars[1].value == 0xFE0F,
           scalars[2].value == 0x20E3 {
            return true
        }

        let regionalIndicators: ClosedRange<UInt32> = 0x1F1E6...0x1F1FF
        if scalars.contains(where: { regionalIndicators.contains($0.value) }) {
            return scalars.count == 2 && scalars.allSatisfy {
                regionalIndicators.contains($0.value)
            }
        }

        if scalars.first?.value == 0x1F3F4,
           scalars.count >= 3,
           scalars.last?.value == 0xE007F {
            let tagLetters: ClosedRange<UInt32> = 0xE0061...0xE007A
            return scalars.dropFirst().dropLast().allSatisfy {
                tagLetters.contains($0.value)
            }
        }

        var index = 0
        guard consumeEmojiComponent(scalars, index: &index) else { return false }
        while index < scalars.count {
            guard scalars[index].value == 0x200D else { return false }
            index += 1
            guard consumeEmojiComponent(scalars, index: &index) else { return false }
        }
        return true
    }

    private static func consumeEmojiComponent(
        _ scalars: [Unicode.Scalar],
        index: inout Int
    ) -> Bool {
        guard index < scalars.count else { return false }
        let base = scalars[index]
        guard base.properties.isEmoji else { return false }
        index += 1

        var hasEmojiVariation = false
        if index < scalars.count, scalars[index].value == 0xFE0F {
            hasEmojiVariation = true
            index += 1
        }
        guard base.properties.isEmojiPresentation || hasEmojiVariation else { return false }

        let emojiModifiers: ClosedRange<UInt32> = 0x1F3FB...0x1F3FF
        if index < scalars.count, emojiModifiers.contains(scalars[index].value) {
            guard base.properties.isEmojiModifierBase else { return false }
            index += 1
        }
        return true
    }
}
