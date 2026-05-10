//
//  TtsEngine.swift
//  万象书屋 iOS · 文本朗读引擎 (M2.6.3 听书 / TTS)
//
//  对应 Android: io.legado.app.service.TTSReadAloudService + HttpReadAloudService
//
//  实现策略:
//   - AVSpeechSynthesizer (系统 TTS, 完全离线, 不收费, 不要 entitlement)
//   - 把章节正文按句号/换行拆成 utterance 队列, 逐句 enqueue
//   - 当前句结束 → 自动下一句 → 整章读完 → 跳下一章
//   - 后台播放: AVAudioSession.playback + spokenAudio mode
//   - 锁屏: MPNowPlayingInfoCenter + MPRemoteCommandCenter (播放/暂停/上下章)
//   - 状态机: idle → loading → speaking → paused → idle
//
//  支持的偏好:
//   - 朗读语速 0.3x ~ 0.6x (AVSpeech rate, AV.minRate=0.0 max=1.0)
//   - 朗读音色: 系统所有中文 voice (zh-CN/zh-TW/zh-HK)
//   - 音调 0.5 ~ 2.0
//   - 音量 0.0 ~ 1.0
//   - 自动滚动 / 高亮当前句 (UI 层订阅 currentUtteranceIdx)
//

import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit

@MainActor
public final class TtsEngine: NSObject, ObservableObject {

    public static let shared = TtsEngine()

    // MARK: - 状态

    public enum State: String { case idle, loading, speaking, paused }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var currentBook: ShelfBook?
    @Published public private(set) var chapters: [BookChapter] = []
    @Published public private(set) var currentChapterIndex: Int = 0
    @Published public private(set) var currentUtteranceIndex: Int = 0
    @Published public private(set) var totalUtterances: Int = 0
    /// 当前正在朗读的句子 (UI 高亮用)
    @Published public private(set) var currentSentence: String = ""

    // 偏好
    @Published public var rate: Float = 0.5 {
        didSet { saveDefault("wx.tts.rate", rate) }
    }
    @Published public var pitch: Float = 1.0 {
        didSet { saveDefault("wx.tts.pitch", pitch) }
    }
    @Published public var volume: Float = 1.0 {
        didSet { saveDefault("wx.tts.volume", volume) }
    }
    @Published public var voiceId: String = "" {
        didSet { saveDefault("wx.tts.voice", voiceId) }
    }
    /// 定时停止 (秒). nil = 不限
    @Published public var sleepRemainingSec: Int? = nil

    // MARK: - 内部

    private let synth = AVSpeechSynthesizer()
    /// 当前章节的所有句子, UI 句子列表用 (P2 fix)
    @Published public private(set) var utterances: [String] = []
    /// 后台续播标识 (iOS 后台被切回前台后 synth 状态可能丢失)
    private var sleepTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - init

    override private init() {
        super.init()
        synth.delegate = self
        loadDefaults()
        setupAudioSession()
        setupRemoteCommands()
    }

    // MARK: - 公共 API

    /// 装载书 + 全部章节, 从指定章开始读
    /// 万象书屋 (M2.8): 如果该书有上次听书断点 (UserDefaults), startIndex 优先用断点位置.
    public func load(book: ShelfBook, chapters: [BookChapter], startIndex: Int) {
        self.currentBook = book
        self.chapters = chapters
        // 万象书屋 (M2.8): 上次中断恢复 — 如果同本书有断点, 优先从断点起.
        let resumeIdx = UserDefaults.standard.object(forKey: "wx.tts.resume.\(book.bookUrl)") as? Int
        let startWith = resumeIdx ?? startIndex
        self.currentChapterIndex = max(0, min(startWith, chapters.count - 1))
        // 万象书屋 (M2.8): 异步加载封面给锁屏 artwork
        loadArtwork()
    }

    /// 万象书屋 (M2.8): 写断点. 退出 / 切书 / 整章读完时调.
    private func saveBookmark() {
        guard let book = currentBook else { return }
        UserDefaults.standard.set(currentChapterIndex, forKey: "wx.tts.resume.\(book.bookUrl)")
    }

    /// 开始朗读 (从当前章 0 句开始)
    public func play() async {
        guard !chapters.isEmpty, let book = currentBook else { return }
        state = .loading
        // 拉章节正文 → 拆句
        let chapter = chapters[currentChapterIndex]
        do {
            let content = try await loadChapterContent(book: book, chapter: chapter)
            utterances = Self.splitSentences(content)
            totalUtterances = utterances.count
            currentUtteranceIndex = 0
            speakCurrent()
            updateNowPlaying()
        } catch {
            print("[TtsEngine] load chapter failed: \(error)")
            state = .idle
        }
    }

    public func pause() {
        if synth.isSpeaking { synth.pauseSpeaking(at: .word) }
        state = .paused
        updateNowPlaying()
    }

    public func resume() {
        if synth.isPaused {
            synth.continueSpeaking()
        } else {
            speakCurrent()
        }
        state = .speaking
        updateNowPlaying()
    }

    public func stop() {
        // 万象书屋 (M2.8): 关之前先存断点
        saveBookmark()
        synth.stopSpeaking(at: .immediate)
        state = .idle
        currentUtteranceIndex = 0
        currentSentence = ""
        clearNowPlaying()
    }

    public func nextChapter() async {
        guard currentChapterIndex + 1 < chapters.count else { stop(); return }
        synth.stopSpeaking(at: .immediate)
        currentChapterIndex += 1
        saveBookmark()
        await play()
    }

    public func prevChapter() async {
        guard currentChapterIndex > 0 else { return }
        synth.stopSpeaking(at: .immediate)
        currentChapterIndex -= 1
        saveBookmark()
        await play()
    }

    /// 万象书屋 (M2.8): 锁屏 / 控制中心快进 — 跳过 N 句 (~30 秒)
    public func skipForward() {
        let target = min(currentUtteranceIndex + 5, utterances.count - 1)
        if target == currentUtteranceIndex { return }
        synth.stopSpeaking(at: .immediate)
        currentUtteranceIndex = target
        speakCurrent()
    }

    public func skipBackward() {
        let target = max(currentUtteranceIndex - 5, 0)
        if target == currentUtteranceIndex { return }
        synth.stopSpeaking(at: .immediate)
        currentUtteranceIndex = target
        speakCurrent()
    }

    /// 跳到指定句子 (UI 点 list)
    public func jumpToSentence(_ idx: Int) {
        guard idx >= 0, idx < utterances.count else { return }
        synth.stopSpeaking(at: .immediate)
        currentUtteranceIndex = idx
        speakCurrent()
    }

    /// 定时关闭 (15/30/60 分钟, nil 取消)
    public func setSleepTimer(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard let m = minutes, m > 0 else {
            sleepRemainingSec = nil
            return
        }
        sleepRemainingSec = m * 60
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if let r = self.sleepRemainingSec {
                    self.sleepRemainingSec = r - 1
                    if r - 1 <= 0 {
                        self.stop()
                        self.sleepRemainingSec = nil
                        self.sleepTimer?.invalidate()
                    }
                }
            }
        }
    }

    /// 列出所有可用的中文音色
    public static var availableChineseVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { v in
            v.language.hasPrefix("zh-")
        }
    }

    // MARK: - 内部: 朗读当前句

    private func speakCurrent() {
        guard currentUtteranceIndex < utterances.count else {
            // 整章读完 → 下一章
            Task { await self.nextChapter() }
            return
        }
        let text = utterances[currentUtteranceIndex]
        currentSentence = text
        let u = AVSpeechUtterance(string: text)
        u.rate = clamp(rate, AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceMaximumSpeechRate)
        u.pitchMultiplier = clamp(pitch, 0.5, 2.0)
        u.volume = clamp(volume, 0.0, 1.0)
        if let voice = pickVoice() { u.voice = voice }
        synth.speak(u)
        state = .speaking
    }

    private func pickVoice() -> AVSpeechSynthesisVoice? {
        if !voiceId.isEmpty, let v = AVSpeechSynthesisVoice(identifier: voiceId) {
            return v
        }
        // 万象书屋 (M2.8): voice 优先级:
        //   1. 用户明确选 (上面)
        //   2. 中文增强音 (premium / enhanced quality, 听感最自然)
        //   3. 中文 default (compact, 系统预装)
        //   4. 任何 zh-* voice
        let allChinese = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
        if let premium = allChinese.first(where: { $0.quality == .premium }) { return premium }
        if let enhanced = allChinese.first(where: { $0.quality == .enhanced }) { return enhanced }
        if let v = AVSpeechSynthesisVoice(language: "zh-CN") {
            return v
        }
        return allChinese.first
    }

    // MARK: - 章节正文加载

    private func loadChapterContent(book: ShelfBook, chapter: BookChapter) async throws -> String {
        // 1. 优先内存 / SQLite cache
        if let cached = try? await ChapterRepository.shared.loadContent(
            bookUrl: book.bookUrl, chapterIndex: chapter.chapterIndex), !cached.isEmpty {
            return cached
        }
        // 2. 本地书: 缓存必须存在, 不然报清楚
        if book.origin.hasPrefix("local://") {
            throw NSError(domain: "Tts", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "本地书章节未导入"])
        }
        // 3. 远端 — 主动从 BookSourceEngine 拉一次, 写回缓存 (P1 fix)
        guard let source = BookSourceRegistry.shared.find(origin: book.origin) else {
            throw NSError(domain: "Tts", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "找不到书源 \(book.origin)"])
        }
        let cont = try await BookSourceEngine.shared.fetchContent(of: chapter, in: source)
        try? await ChapterRepository.shared.saveContent(
            bookUrl: book.bookUrl, chapterIndex: chapter.chapterIndex, content: cont.content)
        return cont.content
    }

    // MARK: - 句子拆分 (中文)

    static func splitSentences(_ text: String) -> [String] {
        // 万象书屋: 中文标点优先 (。！？、；) + 换行作硬切
        // 同时控制: 单句 8~80 字, 太短合并, 太长按逗号再切
        let endChars: Set<Character> = ["。", "！", "？", "!", "?", ".", "\n"]
        var out: [String] = []
        var buf = ""
        for ch in text {
            buf.append(ch)
            if endChars.contains(ch) || buf.count >= 80 {
                let trimmed = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(trimmed) }
                buf = ""
            }
        }
        let tail = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        // 合并过短的句子
        var merged: [String] = []
        for s in out {
            if let last = merged.last, last.count < 8 {
                merged[merged.count - 1] = last + s
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    // MARK: - 持久化

    private func loadDefaults() {
        let d = UserDefaults.standard
        rate = d.object(forKey: "wx.tts.rate") as? Float ?? 0.5
        pitch = d.object(forKey: "wx.tts.pitch") as? Float ?? 1.0
        volume = d.object(forKey: "wx.tts.volume") as? Float ?? 1.0
        voiceId = d.string(forKey: "wx.tts.voice") ?? ""
    }

    private func saveDefault(_ key: String, _ value: Any) {
        UserDefaults.standard.set(value, forKey: key)
    }

    // MARK: - AVAudioSession

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance()
                .setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[TtsEngine] AVAudioSession failed: \(error)")
        }
    }

    // MARK: - 锁屏 / 远程控制

    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.resume() }
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.nextChapter() }
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.prevChapter() }
            return .success
        }
        // 万象书屋 (M2.8): 锁屏快进/快退 30 秒
        cc.skipForwardCommand.preferredIntervals = [30]
        cc.skipForwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipForward() }
            return .success
        }
        cc.skipBackwardCommand.preferredIntervals = [30]
        cc.skipBackwardCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.skipBackward() }
            return .success
        }
        // 万象书屋 (M2.8): 锁屏拖进度条改章节句子位置
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let pos = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in
                guard let self = self, self.totalUtterances > 0 else { return }
                let target = max(0, min(self.totalUtterances - 1, Int(pos.positionTime)))
                self.jumpToSentence(target)
            }
            return .success
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        if let book = currentBook {
            info[MPMediaItemPropertyTitle] = chapters.indices.contains(currentChapterIndex)
                ? chapters[currentChapterIndex].title
                : book.name
            info[MPMediaItemPropertyArtist] = book.name
            info[MPMediaItemPropertyAlbumTitle] = book.author
            // 万象书屋 (M2.8): 锁屏 / 控制中心显示书封面
            if let coverImage = nowPlayingArtwork {
                info[MPMediaItemPropertyArtwork] = coverImage
            }
        }
        info[MPNowPlayingInfoPropertyPlaybackRate] = state == .speaking ? 1.0 : 0.0
        if totalUtterances > 0 {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(currentUtteranceIndex)
            info[MPMediaItemPropertyPlaybackDuration] = Double(totalUtterances)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 万象书屋 (M2.8): 当前书封面 (用于锁屏 artwork). 异步加载, 第一次为 nil,
    /// loadArtwork 完成后下次 updateNowPlaying 就能显示.
    private var nowPlayingArtwork: MPMediaItemArtwork? = nil

    private func loadArtwork() {
        guard let book = currentBook,
              let urlStr = book.coverUrl,
              let url = URL(string: urlStr) else {
            nowPlayingArtwork = nil
            return
        }
        Task {
            // 万象书屋: 简单 URLSession 拉, BookCoverDiskCache 也行但这里独立拿
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.nowPlayingArtwork = art
                self.updateNowPlaying()
            }
        }
    }

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}

// MARK: - AVSpeechSynthesizer delegate

extension TtsEngine: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.currentUtteranceIndex += 1
            // 万象书屋 (M2.8): 读到最后 5 句时, 后台预拉下一章 content (写 SQLite),
            // 让下章接缝时不必等网络. 跟章节缓存一致, fire-and-forget.
            if self.currentUtteranceIndex == max(0, self.utterances.count - 5) {
                self.prefetchNextChapter()
            }
            if self.currentUtteranceIndex >= self.utterances.count {
                await self.nextChapter()
            } else {
                self.speakCurrent()
                self.updateNowPlaying()
            }
        }
    }

    /// 万象书屋 (M2.8): 后台 fire-and-forget 预拉下章正文, 写 SQLite 缓存.
    /// 下次 nextChapter() 调 loadChapterContent 时直接命中.
    @MainActor
    private func prefetchNextChapter() {
        let nextIdx = currentChapterIndex + 1
        guard let book = currentBook, nextIdx < chapters.count else { return }
        let chap = chapters[nextIdx]
        Task.detached(priority: .utility) { [bookUrl = book.bookUrl, origin = book.origin] in
            // 已 cache 跳过
            if let local = try? await ChapterRepository.shared.loadContent(
                bookUrl: bookUrl, chapterIndex: chap.chapterIndex), !local.isEmpty { return }
            guard let source = await BookSourceRegistry.shared.find(origin: origin) else { return }
            guard let cont = try? await BookSourceEngine.shared.fetchContent(of: chap, in: source) else { return }
            try? await ChapterRepository.shared.saveContent(
                bookUrl: bookUrl, chapterIndex: chap.chapterIndex, content: cont.content)
        }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didCancel utterance: AVSpeechUtterance) {
        // 由 stop/jump 主动触发, 不 advance
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                              didPause utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.state = .paused
            self.updateNowPlaying()
        }
    }
}

// MARK: - util

@inline(__always)
private func clamp<T: Comparable>(_ x: T, _ lo: T, _ hi: T) -> T {
    return min(max(x, lo), hi)
}
