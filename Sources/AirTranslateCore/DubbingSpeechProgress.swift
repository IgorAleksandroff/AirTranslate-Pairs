import Foundation

package struct DubbingSpeechProgress {
    private struct PendingStreamingUnit {
        let key: String
        let text: String
        let firstSeenAt: Date
    }

    private struct SpeechUnit {
        let text: String
        let isTerminated: Bool
    }

    private static let maximumRememberedSpeechUnits = 160
    private static let rememberedSpeechUnitTTL: TimeInterval = 45
    private static let minimumStreamingSpeechDwell: TimeInterval = 0.9
    private static let nearDuplicateThreshold = 0.72

    private let now: () -> Date
    private var lastSpokenText = ""
    private var spokenUnitKeys: Set<String> = []
    private var spokenUnitKeyOrder: [(key: String, rememberedAt: Date)] = []
    private var pendingStreamingUnit: PendingStreamingUnit?

    package init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    package mutating func reset() {
        lastSpokenText = ""
        spokenUnitKeys.removeAll()
        spokenUnitKeyOrder.removeAll()
        pendingStreamingUnit = nil
    }

    package mutating func prime(with translatedText: String, languageID: String) {
        let currentText = Self.speechReadyText(translatedText)
        lastSpokenText = currentText
        spokenUnitKeys.removeAll()
        spokenUnitKeyOrder.removeAll()
        pendingStreamingUnit = nil
        rememberSpokenUnits(in: currentText, languageID: languageID, at: now())
    }

    package mutating func unspokenText(
        from translatedText: String,
        languageID: String,
        isFinal: Bool = false
    ) -> String? {
        let currentTime = now()
        expireSpokenUnits(at: currentTime)

        let currentText = Self.speechReadyText(translatedText)
        guard !currentText.isEmpty else { return nil }

        let previousText = lastSpokenText
        let previousKey = Self.normalizedSpeechUnitKey(previousText, languageID: languageID)
        if wasRecentlySpoken(previousKey), Self.isNearDuplicateRevision(
            previous: previousText,
            current: currentText,
            languageID: languageID
        ) {
            lastSpokenText = currentText
            pendingStreamingUnit = nil
            rememberSpokenUnits(in: currentText, languageID: languageID, at: currentTime)
            return nil
        }

        if previousText == currentText,
           let pendingStreamingUnit,
           pendingStreamingUnit.key == Self.normalizedSpeechUnitKey(currentText, languageID: languageID),
           currentTime.timeIntervalSince(pendingStreamingUnit.firstSeenAt)
                >= Self.minimumStreamingSpeechDwell,
           !wasRecentlySpoken(pendingStreamingUnit.key) {
            self.pendingStreamingUnit = nil
            rememberSpokenUnitKey(pendingStreamingUnit.key, at: currentTime)
            return pendingStreamingUnit.text
        }

        guard let delta = Self.speechDelta(previous: previousText, current: currentText) else {
            if Self.shouldAdoptSilentBaselineRevision(
                previous: previousText,
                current: currentText,
                languageID: languageID
            ) {
                lastSpokenText = currentText
                pendingStreamingUnit = nil
                rememberSpokenUnits(in: currentText, languageID: languageID, at: currentTime)
            }
            return nil
        }

        let decision = unspokenSpeechText(
            from: delta,
            languageID: languageID,
            isFinal: isFinal,
            at: currentTime
        )
        guard let unspokenDelta = decision.text else {
            if !decision.hasDeferredUnterminatedUnit,
               Self.shouldAdoptCoveredDeltaBaseline(previous: previousText, current: currentText) {
                lastSpokenText = currentText
                rememberSpokenUnits(in: currentText, languageID: languageID, at: currentTime)
            }
            return nil
        }

        if !decision.hasDeferredUnterminatedUnit {
            lastSpokenText = currentText
        }
        return unspokenDelta
    }

    private static func speechReadyText(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func speechDelta(previous: String, current: String) -> String? {
        guard previous != current else { return nil }
        guard !current.isEmpty else { return nil }

        if previous.isEmpty {
            return current
        }

        if current.hasPrefix(previous) {
            return speakableText(String(current.dropFirst(previous.count)))
        }

        let sharedPrefixLength = commonPrefixLength(previous, current)
        if sharedPrefixLength > previous.count / 2 {
            return speakableText(String(current.dropFirst(sharedPrefixLength)))
        }

        return nil
    }

    private static func speakableText(_ text: String) -> String? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.rangeOfCharacter(from: .letters.union(.decimalDigits)) != nil else {
            return nil
        }
        return trimmedText
    }

    private static func shouldAdoptSilentBaselineRevision(
        previous: String,
        current: String,
        languageID: String
    ) -> Bool {
        guard !previous.isEmpty, !current.isEmpty else { return false }

        let normalizedPrevious = TranscriptTextProcessor.normalizedForComparison(previous)
        let normalizedCurrent = TranscriptTextProcessor.normalizedForComparison(current)
        guard normalizedPrevious != normalizedCurrent else { return false }

        if TranscriptTextProcessor.isWholeTextPrefix(normalizedCurrent, of: normalizedPrevious)
            || TranscriptTextProcessor.isPrefixEndingInsideToken(normalizedCurrent, of: normalizedPrevious) {
            return false
        }

        if normalizedSpeechUnitKey(previous, languageID: languageID)
            == normalizedSpeechUnitKey(current, languageID: languageID) {
            return true
        }

        return TranscriptTextProcessor.isLikelyRecentTranscriptRevision(
            current,
            of: previous,
            allowsExactRepeat: false
        )
    }

    private static func shouldAdoptCoveredDeltaBaseline(previous: String, current: String) -> Bool {
        guard !previous.isEmpty else { return true }
        guard !current.isEmpty else { return false }

        return current.hasPrefix(previous)
    }

    private mutating func unspokenSpeechText(
        from text: String,
        languageID: String,
        isFinal: Bool,
        at currentTime: Date
    ) -> (text: String?, hasDeferredUnterminatedUnit: Bool) {
        let units = Self.speechUnits(from: text)
        guard !units.isEmpty else { return (nil, false) }

        var hasDeferredUnterminatedUnit = false
        var unspokenUnits: [String] = []
        for unit in units {
            let key = Self.normalizedSpeechUnitKey(unit.text, languageID: languageID)
            guard !key.isEmpty else { continue }

            if !isFinal, !unit.isTerminated {
                hasDeferredUnterminatedUnit = true
                continue
            }

            if !isFinal, !canSpeakStreamingUnit(unit, key: key, at: currentTime) {
                hasDeferredUnterminatedUnit = true
                continue
            }

            guard !wasRecentlySpoken(key),
                  !isRecentlySpokenSuffixReplay(key)
            else {
                continue
            }

            pendingStreamingUnit = nil
            rememberSpokenUnitKey(key, at: currentTime)
            unspokenUnits.append(unit.text)
        }

        guard !unspokenUnits.isEmpty else { return (nil, hasDeferredUnterminatedUnit) }
        return (unspokenUnits.joined(separator: " "), hasDeferredUnterminatedUnit)
    }

    private static func speechUnits(from text: String) -> [SpeechUnit] {
        var units: [SpeechUnit] = []
        var currentUnit = ""
        let terminators = CharacterSet(charactersIn: ".!?。！？\n")

        for scalar in text.unicodeScalars {
            currentUnit.unicodeScalars.append(scalar)
            if terminators.contains(scalar) {
                let unit = speechReadyText(currentUnit)
                if !unit.isEmpty {
                    units.append(SpeechUnit(text: unit, isTerminated: true))
                }
                currentUnit = ""
            }
        }

        let remainingUnit = speechReadyText(currentUnit)
        if !remainingUnit.isEmpty {
            units.append(SpeechUnit(text: remainingUnit, isTerminated: false))
        }

        return units
    }

    private mutating func canSpeakStreamingUnit(
        _ unit: SpeechUnit,
        key: String,
        at currentTime: Date
    ) -> Bool {
        defer {
            if pendingStreamingUnit?.key != key {
                pendingStreamingUnit = PendingStreamingUnit(
                    key: key,
                    text: unit.text,
                    firstSeenAt: currentTime
                )
            }
        }

        guard let pendingStreamingUnit,
              pendingStreamingUnit.key == key
        else {
            return false
        }

        return currentTime.timeIntervalSince(pendingStreamingUnit.firstSeenAt)
            >= Self.minimumStreamingSpeechDwell
    }

    private static func normalizedSpeechUnitKey(_ text: String, languageID: String) -> String {
        let foldedText = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: languageID)
        )
        let allowedCharacters = CharacterSet.letters
            .union(.decimalDigits)
            .union(.whitespacesAndNewlines)
        let filteredText = String(foldedText.unicodeScalars.map { scalar in
            allowedCharacters.contains(scalar) ? Character(scalar) : " "
        })

        return filteredText
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isRecentlySpokenSuffixReplay(_ key: String) -> Bool {
        let tokenCount = key.split(separator: " ").count
        guard (1...3).contains(tokenCount) else { return false }

        return spokenUnitKeyOrder.suffix(8).contains { entry in
            Self.isWholeTokenSuffix(key, of: entry.key)
        }
    }

    private func wasRecentlySpoken(_ key: String) -> Bool {
        spokenUnitKeys.contains(key) || spokenUnitKeys.contains { spokenKey in
            Self.bigramSimilarity(spokenKey, key) >= Self.nearDuplicateThreshold
        }
    }

    private static func bigramSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = bigrams(lhs)
        let right = bigrams(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }

        let overlap = left.intersection(right).count
        return (2 * Double(overlap)) / Double(left.count + right.count)
    }

    private static func isNearDuplicateRevision(
        previous: String,
        current: String,
        languageID: String
    ) -> Bool {
        guard !previous.isEmpty, previous != current else { return false }
        guard !current.hasPrefix(previous), !previous.hasPrefix(current) else { return false }

        let previousKey = normalizedSpeechUnitKey(previous, languageID: languageID)
        let currentKey = normalizedSpeechUnitKey(current, languageID: languageID)
        let previousLength = previousKey.filter { !$0.isWhitespace }.count
        let currentLength = currentKey.filter { !$0.isWhitespace }.count
        guard previousLength > 0 else { return false }

        let lengthDifference = abs(previousLength - currentLength)
        guard lengthDifference <= max(3, previousLength / 5) else { return false }
        return bigramSimilarity(previousKey, currentKey) >= nearDuplicateThreshold
    }

    private static func bigrams(_ text: String) -> Set<String> {
        let characters = Array(text.filter { !$0.isWhitespace })
        guard characters.count >= 2 else { return [] }

        return Set((0..<(characters.count - 1)).map { index in
            String(characters[index...index + 1])
        })
    }

    private static func isWholeTokenSuffix(_ suffix: String, of text: String) -> Bool {
        guard text != suffix, text.hasSuffix(suffix) else { return false }
        let prefixEnd = text.index(text.endIndex, offsetBy: -suffix.count)
        guard prefixEnd > text.startIndex else { return false }
        let previous = text[text.index(before: prefixEnd)]
        return previous.isWhitespace
    }

    private mutating func rememberSpokenUnits(in text: String, languageID: String, at currentTime: Date) {
        for unit in Self.speechUnits(from: text) {
            let key = Self.normalizedSpeechUnitKey(unit.text, languageID: languageID)
            if !key.isEmpty {
                rememberSpokenUnitKey(key, at: currentTime)
            }
        }
    }

    private mutating func rememberSpokenUnitKey(_ key: String, at currentTime: Date) {
        spokenUnitKeys.insert(key)
        spokenUnitKeyOrder.append((key, currentTime))

        while spokenUnitKeyOrder.count > Self.maximumRememberedSpeechUnits {
            let removed = spokenUnitKeyOrder.removeFirst()
            if !spokenUnitKeyOrder.contains(where: { $0.key == removed.key }) {
                spokenUnitKeys.remove(removed.key)
            }
        }
    }

    private mutating func expireSpokenUnits(at currentTime: Date) {
        while let first = spokenUnitKeyOrder.first,
              currentTime.timeIntervalSince(first.rememberedAt) >= Self.rememberedSpeechUnitTTL {
            let removed = spokenUnitKeyOrder.removeFirst()
            if !spokenUnitKeyOrder.contains(where: { $0.key == removed.key }) {
                spokenUnitKeys.remove(removed.key)
            }
        }
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var length = 0
        for (leftCharacter, rightCharacter) in zip(lhs, rhs) {
            guard leftCharacter == rightCharacter else { break }
            length += 1
        }
        return length
    }
}
