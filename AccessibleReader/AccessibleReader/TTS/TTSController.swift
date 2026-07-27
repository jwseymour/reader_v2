import Foundation
import AVFoundation
import AppKit

@MainActor
final class TTSController: ObservableObject {
    @Published var isPlaying = false
    @Published var currentSentence: String = ""
    @Published var currentParagraphID: Int?
    @Published var speed: Double = 1.0
    @Published var statusMessage: String = ""
    @Published var useOpenAI: Bool = true

    private var paragraphs: [TTSParagraph] = []
    private var paragraphIndex = 0
    private var sentenceIndex = 0
    private var audioPlayer: AVAudioPlayer?
    private let speech = AVSpeechSynthesizer()
    private let cache = TTSCache()
    private var speechDelegate: SpeechBridge?
    private var prefetchTask: Task<Void, Never>?

    init() {
        let bridge = SpeechBridge()
        bridge.owner = self
        speech.delegate = bridge
        speechDelegate = bridge
    }

    func load(paragraphs: [TTSParagraph]) {
        stop()
        self.paragraphs = paragraphs
        paragraphIndex = 0
        sentenceIndex = 0
    }

    func playFromSelection(_ selected: String?, currentPage: Int) {
        if let selected, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let paras = TTSTextSplitter.paragraphs(from: selected, pageIndex: currentPage)
            load(paragraphs: paras)
            startPlayback()
            return
        }
        // Start from beginning of current page
        if let idx = paragraphs.firstIndex(where: { $0.pageIndex >= currentPage }) {
            paragraphIndex = idx
            sentenceIndex = 0
        } else {
            paragraphIndex = 0
            sentenceIndex = 0
        }
        startPlayback()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            startPlayback()
        }
    }

    func pause() {
        isPlaying = false
        audioPlayer?.pause()
        speech.pauseSpeaking(at: .word)
    }

    func stop() {
        isPlaying = false
        audioPlayer?.stop()
        audioPlayer = nil
        speech.stopSpeaking(at: .immediate)
        currentSentence = ""
        currentParagraphID = nil
        prefetchTask?.cancel()
    }

    func rewindTenSeconds() {
        let seconds = 10.0 * max(speed, 0.1)
        if let player = audioPlayer {
            player.currentTime = max(0, player.currentTime - seconds)
            return
        }
        // Approximate: go back one sentence (or previous)
        if sentenceIndex > 0 {
            sentenceIndex -= 1
        } else if paragraphIndex > 0 {
            paragraphIndex -= 1
            sentenceIndex = max(0, (paragraphs[paragraphIndex].sentences.count) - 1)
        }
        if isPlaying {
            speakCurrent()
        }
    }

    func adjustSpeed(_ delta: Double) {
        speed = min(2.5, max(0.5, speed + delta))
        audioPlayer?.rate = Float(speed)
        if #available(macOS 10.14, *) {
            audioPlayer?.enableRate = true
        }
    }

    private func startPlayback() {
        guard !paragraphs.isEmpty else {
            statusMessage = "No text to speak"
            return
        }
        isPlaying = true
        speakCurrent()
        prefetchAhead()
    }

    private func speakCurrent() {
        guard paragraphs.indices.contains(paragraphIndex) else {
            stop()
            return
        }
        let para = paragraphs[paragraphIndex]
        currentParagraphID = para.id
        let sentences = para.sentences
        guard sentences.indices.contains(sentenceIndex) else {
            paragraphIndex += 1
            sentenceIndex = 0
            speakCurrent()
            return
        }
        let sentence = sentences[sentenceIndex]
        currentSentence = sentence

        let preset = PresetStore.shared.activePreset
        let preferOpenAI = useOpenAI && preset.ttsPreferOpenAI
        let key = SettingsStore.shared.openAIAPIKey

        Task {
            if preferOpenAI, !key.isEmpty {
                do {
                    try await playOpenAI(text: sentence, voice: preset.openAIVoice, apiKey: key)
                    return
                } catch {
                    statusMessage = "OpenAI TTS failed — using macOS voice"
                }
            }
            playMacOS(text: sentence)
        }
    }

    private func playOpenAI(text: String, voice: String, apiKey: String) async throws {
        let model = SettingsStore.shared.openAITTSModel
        let cacheKey = TTSCache.key(provider: "openai-\(model)", voice: voice, text: text)
        var data = await cache.data(forKey: cacheKey)
        if data == nil {
            let client = OpenAITTSClient(apiKey: apiKey, voice: voice, model: model)
            data = try await client.synthesize(text: text)
            if let data { await cache.store(data, forKey: cacheKey) }
        }
        guard let data else { throw TTSError.apiFailed("Empty audio") }
        let player = try AVAudioPlayer(data: data)
        player.enableRate = true
        player.rate = Float(speed)
        player.delegate = speechDelegate
        audioPlayer = player
        player.play()
    }

    private func playMacOS(text: String) {
        let utter = AVSpeechUtterance(string: text)
        utter.rate = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
        utter.voice = AVSpeechSynthesisVoice(language: "en-US")
        speech.speak(utter)
    }

    fileprivate func finishedUtterance() {
        guard isPlaying else { return }
        sentenceIndex += 1
        if paragraphs.indices.contains(paragraphIndex),
           sentenceIndex >= paragraphs[paragraphIndex].sentences.count {
            paragraphIndex += 1
            sentenceIndex = 0
        }
        speakCurrent()
    }

    private func prefetchAhead() {
        prefetchTask?.cancel()
        prefetchTask = Task {
            let start = paragraphIndex
            let end = min(paragraphs.count, start + 3)
            let preset = PresetStore.shared.activePreset
            let key = SettingsStore.shared.openAIAPIKey
            guard preset.ttsPreferOpenAI, !key.isEmpty else { return }
            for i in start..<end {
                for sentence in paragraphs[i].sentences {
                    if Task.isCancelled { return }
                    let model = SettingsStore.shared.openAITTSModel
                    let cacheKey = TTSCache.key(provider: "openai-\(model)", voice: preset.openAIVoice, text: sentence)
                    if await cache.data(forKey: cacheKey) != nil { continue }
                    do {
                        let client = OpenAITTSClient(apiKey: key, voice: preset.openAIVoice, model: model)
                        let data = try await client.synthesize(text: sentence)
                        await cache.store(data, forKey: cacheKey)
                    } catch {
                        return
                    }
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

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in owner?.finishedUtterance() }
    }
}
