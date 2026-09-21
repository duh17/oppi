extension SpinnerStyle {
    var thinkingOrbStyle: ThinkingOrbStyle? {
        switch self {
        case .working: return .working
        case .searching: return .searching
        case .solving: return .solving
        case .brailleDots, .gameOfLife: return nil
        }
    }
}

extension DictationIndicatorStyle {
    var thinkingOrbStyle: ThinkingOrbStyle? {
        switch self {
        case .composing: return .composing
        case .breathing: return .breathing
        case .ring: return nil
        }
    }
}
