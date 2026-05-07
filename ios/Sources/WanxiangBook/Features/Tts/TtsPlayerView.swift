//
//  TtsPlayerView.swift
//  万象书屋 iOS · 听书播放器 UI (M2.6.3)
//

import SwiftUI
import AVFoundation

public struct TtsPlayerView: View {

    public let book: ShelfBook
    public let chapters: [BookChapter]
    public let startIndex: Int

    @StateObject private var tts = TtsEngine.shared
    @State private var showSettings = false
    @State private var showVoicePicker = false
    @State private var showSentenceList = false
    @Environment(\.dismiss) private var dismiss

    public init(book: ShelfBook, chapters: [BookChapter], startIndex: Int) {
        self.book = book
        self.chapters = chapters
        self.startIndex = startIndex
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.title3)
                }
                Spacer()
                Text("听书").font(.headline)
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.title3)
                }
            }
            .padding()

            // 封面 / 当前句卡
            VStack(spacing: 24) {
                Spacer(minLength: 8)
                bookCover
                bookInfo
                currentSentenceCard
                Spacer(minLength: 8)
            }

            // 进度条
            progressBar
                .padding(.horizontal)
                .padding(.bottom, 8)

            // 控制栏
            controlBar
                .padding(.horizontal)
                .padding(.bottom, 24)

            // 定时关闭
            sleepTimerBar
                .padding(.bottom, 8)
        }
        .background(WanxiangColors.background.ignoresSafeArea())
        .onAppear {
            // 万象书屋: 装载 + 自动开播
            tts.load(book: book, chapters: chapters, startIndex: startIndex)
            Task { await tts.play() }
        }
        .sheet(isPresented: $showSettings) {
            ttsSettingsSheet
        }
        .sheet(isPresented: $showSentenceList) {
            sentenceListSheet
        }
    }

    // MARK: - 子视图

    private var bookCover: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(WanxiangColors.primary.opacity(0.6))
            .frame(width: 140, height: 200)
            .overlay {
                VStack {
                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                    Text(book.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .multilineTextAlignment(.center)
                }
            }
            .scaleEffect(tts.state == .speaking ? 1.0 : 0.97)
            .animation(.easeInOut(duration: 0.3), value: tts.state)
    }

    private var bookInfo: some View {
        VStack(spacing: 4) {
            Text(book.name).font(.title3.weight(.semibold))
            if !book.author.isEmpty {
                Text(book.author).font(.caption).foregroundStyle(.secondary)
            }
            if tts.chapters.indices.contains(tts.currentChapterIndex) {
                Text("正在播放: \(tts.chapters[tts.currentChapterIndex].title)")
                    .font(.caption2)
                    .foregroundStyle(WanxiangColors.primary)
                    .lineLimit(1)
            }
        }
    }

    private var currentSentenceCard: some View {
        Button {
            showSentenceList = true
        } label: {
            VStack(spacing: 8) {
                if tts.state == .loading {
                    ProgressView().padding(.vertical, 12)
                } else if tts.currentSentence.isEmpty {
                    Text("等待开始...")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding()
                } else {
                    Text(tts.currentSentence)
                        .font(.body)
                        .lineLimit(4)
                        .multilineTextAlignment(.center)
                        .padding()
                        .frame(maxWidth: .infinity)
                }
            }
            .background(WanxiangColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "list.bullet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }

    private var progressBar: some View {
        VStack(spacing: 4) {
            ProgressView(value: Double(tts.currentUtteranceIndex),
                         total: Double(max(tts.totalUtterances, 1)))
                .tint(WanxiangColors.primary)
            HStack {
                Text("\(tts.currentUtteranceIndex + 1)/\(max(tts.totalUtterances, 1)) 句")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(tts.state.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(stateColor)
            }
        }
    }

    private var stateColor: Color {
        switch tts.state {
        case .speaking: return .green
        case .paused: return .orange
        case .loading: return .blue
        case .idle: return .secondary
        }
    }

    private var controlBar: some View {
        HStack(spacing: 24) {
            Button { Task { await tts.prevChapter() } } label: {
                Image(systemName: "backward.end.fill").font(.title)
            }
            .disabled(tts.currentChapterIndex == 0)

            Button {
                Task {
                    if tts.state == .speaking {
                        tts.pause()
                    } else if tts.state == .paused {
                        tts.resume()
                    } else {
                        await tts.play()
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(WanxiangColors.primary)
                        .frame(width: 64, height: 64)
                    Image(systemName: tts.state == .speaking ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .foregroundStyle(.white)
                }
            }

            Button { Task { await tts.nextChapter() } } label: {
                Image(systemName: "forward.end.fill").font(.title)
            }
            .disabled(tts.currentChapterIndex >= tts.chapters.count - 1)
        }
        .foregroundStyle(WanxiangColors.textPrimary)
    }

    private var sleepTimerBar: some View {
        Menu {
            Button("关闭定时") { tts.setSleepTimer(minutes: nil) }
            Button("15 分钟后") { tts.setSleepTimer(minutes: 15) }
            Button("30 分钟后") { tts.setSleepTimer(minutes: 30) }
            Button("60 分钟后") { tts.setSleepTimer(minutes: 60) }
            Button("90 分钟后") { tts.setSleepTimer(minutes: 90) }
        } label: {
            HStack {
                Image(systemName: "moon.zzz")
                if let s = tts.sleepRemainingSec {
                    Text("\(s / 60):\(String(format: "%02d", s % 60)) 后停止")
                } else {
                    Text("定时关闭")
                }
            }
            .font(.caption)
            .foregroundStyle(WanxiangColors.primary)
            .padding(.vertical, 6).padding(.horizontal, 12)
            .background(Capsule().stroke(WanxiangColors.primary.opacity(0.4)))
        }
    }

    // MARK: - 设置 sheet

    private var ttsSettingsSheet: some View {
        NavigationStack {
            Form {
                Section("语速") {
                    HStack {
                        Image(systemName: "tortoise")
                        Slider(value: $tts.rate,
                               in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate)
                        Image(systemName: "hare")
                    }
                    Text("当前: \(String(format: "%.2f", tts.rate))").font(.caption)
                }
                Section("音调") {
                    Slider(value: $tts.pitch, in: 0.5...2.0)
                    Text("当前: \(String(format: "%.2f", tts.pitch))").font(.caption)
                }
                Section("音量") {
                    Slider(value: $tts.volume, in: 0.0...1.0)
                    Text("当前: \(Int(tts.volume * 100))%").font(.caption)
                }
                Section("音色") {
                    NavigationLink {
                        VoicePickerView()
                    } label: {
                        HStack {
                            Text("当前音色")
                            Spacer()
                            Text(currentVoiceName)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .navigationTitle("听书设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showSettings = false }
                }
            }
        }
    }

    private var currentVoiceName: String {
        if let id = tts.voiceId.isEmpty ? nil : tts.voiceId,
           let v = AVSpeechSynthesisVoice(identifier: id) {
            return "\(v.name) · \(v.language)"
        }
        return "系统默认 (zh-CN)"
    }

    // MARK: - 句子列表 sheet

    private var sentenceListSheet: some View {
        NavigationStack {
            // 万象书屋: 用 ScrollViewReader 自动滚到当前句
            ScrollViewReader { proxy in
                List(Array(tts.utterances.enumerated()), id: \.offset) { idx, sentence in
                    Button {
                        tts.jumpToSentence(idx)
                        showSentenceList = false
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Text("\(idx + 1).")
                                .foregroundStyle(.secondary)
                                .font(.caption2.monospacedDigit())
                            Text(sentence)
                                .lineLimit(3)
                                .foregroundStyle(idx == tts.currentUtteranceIndex
                                                 ? WanxiangColors.primary : WanxiangColors.textPrimary)
                                .font(.subheadline)
                        }
                    }
                    .id(idx)
                }
                .navigationTitle("句子列表 (\(tts.utterances.count))")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    proxy.scrollTo(tts.currentUtteranceIndex, anchor: .center)
                }
            }
        }
    }
}

private struct VoicePickerView: View {
    @StateObject private var tts = TtsEngine.shared
    var body: some View {
        List {
            Button {
                tts.voiceId = ""
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text("系统默认").font(.subheadline)
                        Text("zh-CN").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if tts.voiceId.isEmpty { Image(systemName: "checkmark").foregroundStyle(WanxiangColors.primary) }
                }
            }
            ForEach(TtsEngine.availableChineseVoices, id: \.identifier) { v in
                Button {
                    tts.voiceId = v.identifier
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(v.name).font(.subheadline)
                            Text("\(v.language) · \(v.quality == .enhanced ? "增强" : "默认")")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if tts.voiceId == v.identifier {
                            Image(systemName: "checkmark").foregroundStyle(WanxiangColors.primary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("选择音色")
        .navigationBarTitleDisplayMode(.inline)
    }
}
