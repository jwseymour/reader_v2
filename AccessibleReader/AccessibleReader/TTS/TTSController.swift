import Foundation
import AVFoundation
import AppKit

@MainActor
final class TTSController: ObservableObject {
    @Published var isPlaying = false
    /// The text currently drawn as the DOM highlight — a whole sentence or a
    /// moving word window, depending on `ReadingPreset.effectiveTTSHighlightMode`.
    @Published var currentHighlight: String = ""
    @Published var currentParagraphID: Int?
    @Published var speed: Double = 1.0
    @Published var statusMessage: String = ""

    /// The whole document. Playback always reads from here; `paragraphIndex` is
    /// the read pointer — where the next Play press starts from. It defaults to
    /// the top (`load`), advances as paragraphs finish (`finishedUtterance`), and
    /// jumps to wherever the document's current selection is when Play is
    /// pressed (see `resume(selection:currentPage:)`).
    private var allParagraphs: [TTSParagraph] = []
    private var paragraphIndex = 0
    /// Character offset into `allParagraphs[paragraphIndex].text` to start from.
    /// Only meaningful for the paragraph the pointer was last moved to — a jump
    /// can land mid-paragraph, but once that paragraph finishes, playback
    /// continues in full from the next one.
    private var pointerOffset = 0
    private var audioPlayer: AVAudioPlayer?
    private let speech = AVSpeechSynthesizer()
    private let cache = TTSCache()
    private var speechDelegate: SpeechBridge?
    private var prefetchTask: Task<Void, Never>?
    /// Drives the sentence highlight during OpenAI playback by polling elapsed
    /// time against estimated per-sentence offsets (no true word-timing exists
    /// for a synthesized clip). The macOS voice path gets exact highlighting
    /// instead, from the synthesizer's own word-boundary callbacks.
    private var highlightTask: Task<Void, Never>?
    /// Character offset where each sentence starts within the current paragraph's
    /// text, used by both the OpenAI proportional-timing estimate and the macOS
    /// exact-range delegate callback.
    private var currentSentenceOffsets: [Int] = []
    /// Range of each word within the current paragraph's text, used the same way
    /// as `currentSentenceOffsets` but for the word-window highlight mode.
    private var currentWordRanges: [NSRange] = []
    /// Bumped on every new utterance so results from a superseded async synthesis
    /// can be discarded instead of hijacking playback after a stop or a skip.
    private var generation = 0

    init() {
        let bridge = SpeechBridge()
        bridge.owner = self
        speech.delegate = bridge
        speechDelegate = bridge
    }

    func load(paragraphs: [TTSParagraph]) {
        stop()
        self.allParagraphs = paragraphs
        paragraphIndex = 0
        pointerOffset = 0
    }


    /// Finds the paragraph containing `selection` (matched on the first ~60
    /// characters with whitespace collapsed, since a raw selection's line breaks
    /// rarely match the extracted text's exactly) and returns the character
    /// offset within that paragraph's original text where the match begins.
    /// Prefers a match at or after `currentPage` when the same text could
    /// plausibly appear more than once (e.g. a repeated heading).
    private static func locate(
        _ selection: String,
        in source: [TTSParagraph],
        preferringPageAt currentPage: Int
    ) -> (index: Int, offset: Int)? {
        let (normalizedSelection, _) = normalizeWithMapping(selection)
        let marker = String(normalizedSelection.prefix(60))
        guard !marker.isEmpty else { return nil }

        var best: (index: Int, offset: Int)?
        for (index, para) in source.enumerated() {
            let (normalizedPara, mapping) = normalizeWithMapping(para.text)
            guard let range = normalizedPara.range(of: marker) else { continue }
            let normalizedStart = normalizedPara.distance(from: normalizedPara.startIndex, to: range.lowerBound)
            guard mapping.indices.contains(normalizedStart) else { continue }
            let originalOffset = mapping[normalizedStart]

            if best == nil { best = (index, originalOffset) }
            if para.pageIndex >= currentPage {
                best = (index, originalOffset)
                break
            }
        }
        return best
    }

    /// The paragraph to actually speak at `index` — the full paragraph, unless
    /// `index` is where the read pointer was last moved to, in which case it's
    /// truncated to start at `pointerOffset`.
    private func effectiveParagraph(at index: Int) -> TTSParagraph? {
        guard allParagraphs.indices.contains(index) else { return nil }
        let para = allParagraphs[index]
        guard index == paragraphIndex, pointerOffset > 0,
              let stringIndex = para.text.index(
                para.text.startIndex, offsetBy: pointerOffset, limitedBy: para.text.endIndex
              ) else { return para }
        let remainder = String(para.text[stringIndex...])
        guard !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return para }
        return TTSParagraph(id: para.id, pageIndex: para.pageIndex, text: remainder, sentences: TTSTextSplitter.splitSentences(remainder))
    }

    /// Collapses whitespace runs to single spaces while recording each output
    /// character's index in the original string, so a match found in the
    /// normalized text can be mapped back to slice the original.
    private static func normalizeWithMapping(_ text: String) -> (String, [Int]) {
        var normalized = ""
        var mapping: [Int] = []
        var lastWasSpace = true
        for (i, ch) in text.enumerated() {
            if ch.isWhitespace {
                if !lastWasSpace {
                    normalized.append(" ")
                    mapping.append(i)
                    lastWasSpace = true
                }
            } else {
                normalized.append(ch)
                mapping.append(i)
                lastWasSpace = false
            }
        }
        return (normalized, mapping)
    }

    /// `selection`/`currentPage` describe whatever is currently highlighted in the
    /// document, if anything — passed through so Play can jump the read pointer
    /// there. Merely selecting text never touches playback (see `resume`); it
    /// only matters at the moment Play is actually pressed.
    func togglePlayPause(selection: String? = nil, currentPage: Int = 0) {
        if isPlaying {
            pause()
        } else {
            resume(selection: selection, currentPage: currentPage)
        }
    }

    func pause() {
        guard isPlaying else { return }
        isPlaying = false
        prefetchTask?.cancel()
        highlightTask?.cancel()
        if let player = audioPlayer, player.isPlaying {
            player.pause()
        } else if speech.isSpeaking {
            speech.pauseSpeaking(at: .word)
        }
    }

    /// Continues from exactly where `pause()` left off, unless `selection` is a
    /// non-empty passage found in the document — in which case the read pointer
    /// jumps there first and any suspended utterance is discarded, since it's no
    /// longer where playback should continue from. With no selection, resumes
    /// from wherever the pointer already is.
    func resume(selection: String? = nil, currentPage: Int = 0) {
        guard !isPlaying else { return }
        guard !allParagraphs.isEmpty else {
            statusMessage = "No text to speak"
            return
        }
        if let selection, !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let match = Self.locate(selection, in: allParagraphs, preferringPageAt: currentPage) {
            stop()
            paragraphIndex = match.index
            pointerOffset = match.offset
        }
        isPlaying = true
        statusMessage = ""
        if let player = audioPlayer {
            player.play()
            if let para = effectiveParagraph(at: paragraphIndex) {
                startHighlightTimer(for: para, token: generation)
            }
        } else if speech.isPaused {
            speech.continueSpeaking()
        } else {
            speakCurrentParagraph()
        }
        prefetchAhead()
    }

    func stop() {
        isPlaying = false
        generation += 1
        audioPlayer?.stop()
        audioPlayer = nil
        speech.stopSpeaking(at: .immediate)
        currentHighlight = ""
        currentParagraphID = nil
        prefetchTask?.cancel()
        highlightTask?.cancel()
    }

    func rewindTenSeconds() {
        let seconds = 10.0 * max(speed, 0.1)
        if let player = audioPlayer {
            if player.currentTime - seconds < 0.15, paragraphIndex > 0 {
                paragraphIndex -= 1
                pointerOffset = 0
                if isPlaying { speakCurrentParagraph() }
                return
            }
            player.currentTime = max(0, player.currentTime - seconds)
            return
        }
        // AVSpeechSynthesizer has no true seek; approximate by restarting the
        // paragraph, or the previous one if this one just started.
        if paragraphIndex > 0 {
            paragraphIndex -= 1
            pointerOffset = 0
        }
        if isPlaying { speakCurrentParagraph() }
    }

    func adjustSpeed(_ delta: Double) {
        speed = min(2.5, max(0.5, speed + delta))
        audioPlayer?.enableRate = true
        audioPlayer?.rate = Float(speed)
    }

    /// Speaks one whole paragraph as a single utterance/audio clip — the unit the
    /// text was already chunked into for TTS (~400–800 chars). The previous
    /// implementation chunked text into paragraphs but then synthesized and
    /// played it one sentence at a time, with a network round-trip between each,
    /// which is what produced the long gaps between sentences.
    private func speakCurrentParagraph() {
        guard let para = effectiveParagraph(at: paragraphIndex) else {
            stop()
            return
        }
        currentParagraphID = para.id
        currentSentenceOffsets = Self.sentenceOffsets(for: para)
        currentWordRanges = Self.wordRanges(for: para)
        currentHighlight = highlightText(forCharacterOffset: 0, in: para) ?? para.sentences.first ?? ""

        generation += 1
        let token = generation
        let preset = PresetStore.shared.activePreset

        if preset.ttsPreferOpenAI {
            guard !SettingsStore.shared.openAIAPIKey.isEmpty else {
                statusMessage = "OpenAI TTS needs an API key — add one in Speech settings, or switch to macOS (Free)"
                isPlaying = false
                return
            }
            Task {
                await attemptOpenAI(paragraph: para, voice: preset.openAIVoice, token: token)
            }
        } else {
            playMacOS(paragraph: para)
            prefetchAhead()
        }
    }

    /// Speaks `paragraph` via the OpenAI engine. The user explicitly chose this
    /// engine, so a failure pauses playback with a clear error rather than
    /// silently switching to the macOS voice — that switch would be surprising
    /// and easy to miss.
    private func attemptOpenAI(paragraph: TTSParagraph, voice: String, token: Int) async {
        do {
            try await playOpenAI(paragraph: paragraph, voice: voice,
                                 apiKey: SettingsStore.shared.openAIAPIKey, token: token)
            statusMessage = ""
            prefetchAhead()
        } catch TTSError.unauthorized {
            // A revoked key in the Keychain can be superseded by a fresh one in
            // `.env` — swap and retry once before surfacing the error.
            if SettingsStore.shared.handleRejectedKey() {
                do {
                    try await playOpenAI(paragraph: paragraph, voice: voice,
                                         apiKey: SettingsStore.shared.openAIAPIKey, token: token)
                    statusMessage = ""
                    prefetchAhead()
                    return
                } catch {}
            }
            guard token == generation else { return }
            statusMessage = "OpenAI rejected the API key — playback paused"
            isPlaying = false
        } catch {
            guard token == generation else { return }
            statusMessage = "OpenAI TTS failed — playback paused"
            isPlaying = false
        }
    }

    private func playOpenAI(paragraph: TTSParagraph, voice: String, apiKey: String, token: Int) async throws {
        let model = SettingsStore.shared.openAITTSModel
        let cacheKey = TTSCache.key(provider: "openai-\(model)", voice: voice, text: paragraph.text)
        var data = await cache.data(forKey: cacheKey)
        if data == nil {
            let client = OpenAITTSClient(apiKey: apiKey, voice: voice, model: model)
            data = try await client.synthesize(text: paragraph.text)
            if let data { await cache.store(data, forKey: cacheKey) }
        }
        guard let data else { throw TTSError.apiFailed("Empty audio") }
        // Synthesis is slow enough that playback may have been stopped or moved on.
        guard token == generation, isPlaying else { return }
        let player = try AVAudioPlayer(data: data)
        player.enableRate = true
        player.rate = Float(speed)
        player.delegate = speechDelegate
        audioPlayer = player
        player.play()
        startHighlightTimer(for: paragraph, token: token)
    }

    private func playMacOS(paragraph: TTSParagraph) {
        let utter = AVSpeechUtterance(string: paragraph.text)
        utter.rate = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
        utter.voice = AVSpeechSynthesisVoice(language: "en-US")
        speech.speak(utter)
    }

    /// OpenAI's audio API returns no word/sentence timing, so the highlight has to
    /// be estimated: poll playback progress and map it onto sentence start
    /// offsets by character-position fraction. Approximate, but keeps the
    /// highlight moving smoothly through a paragraph-length clip instead of
    /// jumping once per (now nonexistent) per-sentence request.
    private func startHighlightTimer(for paragraph: TTSParagraph, token: Int) {
        highlightTask?.cancel()
        let totalLength = max(1, paragraph.text.count)
        guard !currentSentenceOffsets.isEmpty, !currentWordRanges.isEmpty else { return }

        highlightTask = Task { [weak self] in
            while true {
                guard let self, !Task.isCancelled, token == self.generation,
                      let player = self.audioPlayer else { return }
                if player.duration > 0 {
                    let progress = player.currentTime / player.duration
                    let position = Int(progress * Double(totalLength))
                    if let text = self.highlightText(forCharacterOffset: position, in: paragraph),
                       self.currentHighlight != text {
                        self.currentHighlight = text
                    }
                }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    /// Exact highlight for the macOS voice path, driven by the synthesizer's own
    /// word-boundary callback rather than an estimate.
    fileprivate func updateHighlight(forCharacterOffset offset: Int) {
        guard let para = effectiveParagraph(at: paragraphIndex) else { return }
        if let text = highlightText(forCharacterOffset: offset, in: para), currentHighlight != text {
            currentHighlight = text
        }
    }

    /// The text to highlight for a given character offset into `paragraph.text`,
    /// under whichever `TTSHighlightMode` the active preset has selected — either
    /// the enclosing sentence, or a window of a few words centred on the word at
    /// that offset. Shared by both the macOS exact callback and the OpenAI
    /// proportional-timing estimate, which each just compute `offset` differently.
    private func highlightText(forCharacterOffset offset: Int, in paragraph: TTSParagraph) -> String? {
        switch PresetStore.shared.activePreset.effectiveTTSHighlightMode {
        case .sentence:
            let sentences = paragraph.sentences
            guard !currentSentenceOffsets.isEmpty, !sentences.isEmpty else { return nil }
            var index = 0
            for (i, start) in currentSentenceOffsets.enumerated() where start <= offset { index = i }
            return sentences[min(index, sentences.count - 1)]
        case .wordWindow:
            guard !currentWordRanges.isEmpty else { return nil }
            var index = 0
            for (i, range) in currentWordRanges.enumerated() where range.location <= offset { index = i }
            let half = PresetStore.shared.activePreset.effectiveTTSHighlightWindowSize
            let lo = max(0, index - half)
            let hi = min(currentWordRanges.count - 1, index + half)
            let start = currentWordRanges[lo].location
            let end = currentWordRanges[hi].location + currentWordRanges[hi].length
            let full = paragraph.text as NSString
            guard start >= 0, end <= full.length, start < end else { return nil }
            return full.substring(with: NSRange(location: start, length: end - start))
        }
    }

    fileprivate func finishedUtterance() {
        guard isPlaying else { return }
        highlightTask?.cancel()
        paragraphIndex += 1
        pointerOffset = 0
        speakCurrentParagraph()
    }

    /// Character offset where each sentence starts within `paragraph.text`,
    /// found by sequential search (sentences were extracted from this same text
    /// in order, so each search can resume from where the last one ended).
    private static func sentenceOffsets(for paragraph: TTSParagraph) -> [Int] {
        let text = paragraph.text as NSString
        var offsets: [Int] = []
        var searchStart = 0
        for sentence in paragraph.sentences {
            guard searchStart <= text.length else {
                offsets.append(offsets.last ?? 0)
                continue
            }
            let range = text.range(of: sentence, range: NSRange(location: searchStart, length: text.length - searchStart))
            let start = range.location != NSNotFound ? range.location : searchStart
            offsets.append(start)
            if range.location != NSNotFound { searchStart = range.location + range.length }
        }
        return offsets
    }

    /// Range of each word in `paragraph.text`, in order. Used to build the
    /// word-window highlight: given the range of the word currently being
    /// spoken, slicing from a few entries before to a few after yields a
    /// contiguous substring of the original text (punctuation and spacing
    /// intact), which is what the DOM highlight needs to find an exact match.
    private static func wordRanges(for paragraph: TTSParagraph) -> [NSRange] {
        let text = paragraph.text
        var ranges: [NSRange] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .localized]) { _, range, _, _ in
            ranges.append(NSRange(range, in: text))
        }
        return ranges
    }

    /// Keeps audio for the next couple of paragraphs ready before they're needed,
    /// so playback crosses a paragraph boundary with no gap. Paragraphs are
    /// already sized generously (tens of seconds of speech), so synthesizing one
    /// ahead comfortably outruns network latency.
    private func prefetchAhead() {
        prefetchTask?.cancel()
        prefetchTask = Task {
            let start = paragraphIndex + 1
            let end = min(allParagraphs.count, start + 2)
            guard start < end else { return }
            let preset = PresetStore.shared.activePreset
            let key = SettingsStore.shared.openAIAPIKey
            guard preset.ttsPreferOpenAI, !key.isEmpty else { return }
            let model = SettingsStore.shared.openAITTSModel
            for i in start..<end {
                if Task.isCancelled { return }
                let text = allParagraphs[i].text
                let cacheKey = TTSCache.key(provider: "openai-\(model)", voice: preset.openAIVoice, text: text)
                if await cache.data(forKey: cacheKey) != nil { continue }
                do {
                    let client = OpenAITTSClient(apiKey: key, voice: preset.openAIVoice, model: model)
                    let data = try await client.synthesize(text: text)
                    await cache.store(data, forKey: cacheKey)
                } catch {
                    return
                }
            }
        }
    }
}

private final class SpeechBridge: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    weak var owner: TTSController?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in owner?.finishedUtterance() }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in owner?.updateHighlight(forCharacterOffset: characterRange.location) }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in owner?.finishedUtterance() }
    }
}
