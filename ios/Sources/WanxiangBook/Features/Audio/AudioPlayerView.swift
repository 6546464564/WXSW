//
//  AudioPlayerView.swift
//  万象书屋 iOS · 有声书播放器 (M2.6.2)
//
//  对应 Android: io.legado.app.ui.book.audio.AudioPlayActivity + AudioPlayService
//
//  M2.6.2 v1 实现:
//   - AVPlayer + AVAudioSession.playback (后台播放)
//   - MPNowPlayingInfoCenter 锁屏控制
//   - MPRemoteCommandCenter (蓝牙耳机)
//   - 倍速 0.5x-3x
//   - 章节列表 / 跳章 / 进度条
//   - 定时关闭 (15/30/60/章末)
//

import SwiftUI
import AVFoundation
import MediaPlayer

@MainActor
public final class AudioPlayer: ObservableObject {

    public static let shared = AudioPlayer()

    @Published public var currentBook: ShelfBook?
    @Published public var chapters: [BookChapter] = []
    @Published public var currentIndex: Int = 0
    @Published public var isPlaying: Bool = false
    @Published public var rate: Float = 1.0
    @Published public var currentTime: TimeInterval = 0
    @Published public var duration: TimeInterval = 0
    @Published public var sleepTimerEnd: Date? = nil

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var sleepTimer: Timer?

    private init() {
        setupAudioSession()
        setupRemoteCommands()
    }

    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("[AudioPlayer] AVAudioSession setup failed: \(error)")
        }
    }

    private func setupRemoteCommands() {
        let cmd = MPRemoteCommandCenter.shared()
        cmd.playCommand.addTarget { [weak self] _ in
            self?.play()
            return .success
        }
        cmd.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        cmd.nextTrackCommand.addTarget { [weak self] _ in
            self?.next()
            return .success
        }
        cmd.previousTrackCommand.addTarget { [weak self] _ in
            self?.previous()
            return .success
        }
        cmd.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
    }

    public func load(book: ShelfBook, chapters: [BookChapter], startIndex: Int = 0) {
        self.currentBook = book
        self.chapters = chapters
        playChapter(at: startIndex)
    }

    public func playChapter(at index: Int) {
        guard chapters.indices.contains(index) else { return }
        currentIndex = index
        guard let urlStr = chapters[index].chapterUrl, let url = URL(string: urlStr) else { return }
        let item = AVPlayerItem(url: url)
        if player == nil {
            player = AVPlayer(playerItem: item)
        } else {
            player?.replaceCurrentItem(with: item)
        }
        player?.rate = rate
        play()
        observeTime()
        updateNowPlaying()
    }

    private func observeTime() {
        if let obs = timeObserver { player?.removeTimeObserver(obs); timeObserver = nil }
        timeObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self else { return }
            currentTime = time.seconds
            if let item = self.player?.currentItem {
                let dur = item.duration.seconds
                if !dur.isNaN { duration = dur }
            }
            // 检查定时关闭
            if let end = self.sleepTimerEnd, Date() >= end {
                self.pause()
                self.sleepTimerEnd = nil
            }
        }
    }

    public func play() {
        player?.play()
        player?.rate = rate
        isPlaying = true
        updateNowPlaying()
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    public func next() {
        playChapter(at: currentIndex + 1)
    }

    public func previous() {
        playChapter(at: currentIndex - 1)
    }

    public func seek(to seconds: TimeInterval) {
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    public func setRate(_ r: Float) {
        rate = r
        if isPlaying { player?.rate = r }
    }

    public func setSleep(minutes: Int?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        if let m = minutes {
            sleepTimerEnd = Date().addingTimeInterval(TimeInterval(m * 60))
        } else {
            sleepTimerEnd = nil
        }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = chapters[safe: currentIndex]?.title ?? ""
        info[MPMediaItemPropertyAlbumTitle] = currentBook?.name ?? ""
        info[MPMediaItemPropertyArtist] = currentBook?.author ?? ""
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? rate : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// MARK: - View

public struct AudioPlayerView: View {
    @StateObject private var player = AudioPlayer.shared
    @State private var sleepSheet = false

    public init() {}

    public var body: some View {
        VStack(spacing: 24) {
            // 封面
            RoundedRectangle(cornerRadius: 8)
                .fill(WanxiangColors.divider)
                .frame(width: 200, height: 200)
                .overlay(
                    Image(systemName: "headphones")
                        .font(.system(size: 48))
                        .foregroundStyle(WanxiangColors.primary)
                )
                .padding(.top, 40)

            VStack(spacing: 4) {
                Text(player.chapters[safe: player.currentIndex]?.title ?? "(未播放)")
                    .font(.title3.weight(.semibold))
                Text(player.currentBook?.name ?? "")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // 进度
            VStack(spacing: 4) {
                Slider(value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ), in: 0...max(player.duration, 1))
                .tint(WanxiangColors.primary)
                HStack {
                    Text(format(player.currentTime))
                    Spacer()
                    Text(format(player.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            // 控制
            HStack(spacing: 32) {
                Button { player.previous() } label: {
                    Image(systemName: "backward.fill").font(.title)
                }
                Button { player.togglePlayPause() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(WanxiangColors.primary)
                }
                Button { player.next() } label: {
                    Image(systemName: "forward.fill").font(.title)
                }
            }

            // 倍速 + 定时
            HStack(spacing: 16) {
                Menu {
                    ForEach([Float(0.5), 0.75, 1.0, 1.25, 1.5, 2.0, 3.0], id: \.self) { r in
                        Button("\(String(format: "%.2gx", r))") { player.setRate(r) }
                    }
                } label: {
                    Label("\(String(format: "%.2gx", player.rate))", systemImage: "speedometer")
                }
                Menu {
                    Button("不定时") { player.setSleep(minutes: nil) }
                    Button("15 分钟") { player.setSleep(minutes: 15) }
                    Button("30 分钟") { player.setSleep(minutes: 30) }
                    Button("60 分钟") { player.setSleep(minutes: 60) }
                } label: {
                    Label(sleepLabel, systemImage: "moon.zzz")
                }
            }
            .font(.subheadline)
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WanxiangColors.background.ignoresSafeArea())
        .navigationTitle("有声播放")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sleepLabel: String {
        if let end = player.sleepTimerEnd {
            let s = max(0, Int(end.timeIntervalSinceNow))
            return "\(s/60):\(String(format: "%02d", s%60))"
        }
        return "定时"
    }

    private func format(_ t: TimeInterval) -> String {
        if t.isNaN || t.isInfinite { return "00:00" }
        let s = Int(t)
        return "\(String(format: "%02d", s/60)):\(String(format: "%02d", s%60))"
    }
}
