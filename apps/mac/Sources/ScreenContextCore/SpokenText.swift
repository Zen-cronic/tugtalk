import Foundation
import NaturalLanguage

/// Prepares a card's text to be said out loud on this Mac: its first sentence, and the language it is written in.
public enum SpokenText {
    /// The first sentence, found with sentence segmentation, so "2.5 words a second" or "e.g." is not cut.
    /// At most `maxWords` words.
    public static func firstSentence(_ text: String, maxWords: Int = 24) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed
        var sentence = trimmed
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { range, _ in
            sentence = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return false
        }
        let words = sentence.split(separator: " ")
        return words.count > maxWords ? words.prefix(maxWords).joined(separator: " ") + "." : sentence
    }

    /// The language a card's sentence is written in, among the voices we have. Very short or mixed text the
    /// recognizer is unsure about gets `fallback` (the record's language, or the voice setting).
    public static func language(of text: String, fallback: VoiceLanguage) -> VoiceLanguage {
        // A word or two says too little about the language.
        guard text.split(whereSeparator: { $0.isWhitespace }).count >= 3 else { return fallback }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .french]
        recognizer.processString(text)
        guard let (top, confidence) = recognizer.languageHypotheses(withMaximum: 1).first, confidence >= 0.8 else { return fallback }
        switch top {
        case .english: return .en
        case .french: return .fr
        default: return fallback
        }
    }
}
