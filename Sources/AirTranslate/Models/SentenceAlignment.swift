import Foundation

/// Word-level correspondence between a source sentence and its translation.
/// Indices refer to whitespace tokens produced by `WordTokens.split`.
struct SentenceAlignment: Equatable {
    let sourceToTarget: [Int: Set<Int>]
    let targetToSource: [Int: Set<Int>]

    static let empty = SentenceAlignment(sourceToTarget: [:], targetToSource: [:])

    init(sourceToTarget: [Int: Set<Int>], targetToSource: [Int: Set<Int>]) {
        self.sourceToTarget = sourceToTarget
        self.targetToSource = targetToSource
    }

    init(pairs: some Sequence<(Int, Int)>) {
        var sourceToTarget: [Int: Set<Int>] = [:]
        var targetToSource: [Int: Set<Int>] = [:]
        for (source, target) in pairs {
            sourceToTarget[source, default: []].insert(target)
            targetToSource[target, default: []].insert(source)
        }
        self.init(sourceToTarget: sourceToTarget, targetToSource: targetToSource)
    }
}

enum WordTokens {
    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func normalized(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).lowercased()
    }

    /// Prefix match tolerant to inflection: "исследование" ~ "исследования", "studies" ~ "study".
    static func stemsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        let shorter = min(lhs.count, rhs.count)
        guard shorter >= 4 else { return false }
        let prefix = zip(lhs, rhs).prefix { $0 == $1 }.count
        return prefix >= 4 && prefix >= shorter - 3
    }
}
