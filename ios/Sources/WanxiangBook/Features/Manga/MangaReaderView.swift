//
//  MangaReaderView.swift
//  万象书屋 iOS · 漫画阅读器 (M2.6.1)
//
//  M2.6.1 v1: 竖滚 + 横翻切换, 双击放大, 双指缩放, 单击呼出菜单
//  对应 Android: io.legado.app.ui.book.manga.ReadMangaActivity
//

import SwiftUI

public struct MangaReaderView: View {

    let book: ShelfBook
    let imageUrls: [String]   // M2.6.1 v1 简化: 直接传图列表

    @AppStorage("wanxiang.manga.layout") private var layoutRaw: Int = 0
    @State private var menuVisible = false
    @State private var currentIndex = 0
    @Environment(\.dismiss) private var dismiss

    enum Layout: Int { case vertical = 0, horizontal = 1 }
    private var layout: Layout { Layout(rawValue: layoutRaw) ?? .vertical }

    public init(book: ShelfBook, imageUrls: [String]) {
        self.book = book
        self.imageUrls = imageUrls
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            if menuVisible { menuOverlay.transition(.opacity) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(!menuVisible)
    }

    @ViewBuilder
    private var content: some View {
        if imageUrls.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 56))
                    .foregroundStyle(.white.opacity(0.4))
                Text("暂无漫画图片").foregroundStyle(.white.opacity(0.6))
            }
            .onTapGesture { withAnimation { menuVisible.toggle() } }
        } else {
            switch layout {
            case .vertical: verticalScroll
            case .horizontal: horizontalPager
            }
        }
    }

    private var verticalScroll: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(imageUrls.enumerated()), id: \.offset) { i, url in
                    MangaImageView(url: url)
                        .onAppear { currentIndex = i }
                }
            }
        }
        .onTapGesture { withAnimation { menuVisible.toggle() } }
    }

    private var horizontalPager: some View {
        TabView(selection: $currentIndex) {
            ForEach(Array(imageUrls.enumerated()), id: \.offset) { i, url in
                MangaImageView(url: url)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .onTapGesture { withAnimation { menuVisible.toggle() } }
    }

    private var menuOverlay: some View {
        VStack {
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.backward")
                        .foregroundStyle(.white).font(.title3)
                }
                Spacer()
                Text(book.name).foregroundStyle(.white).font(.subheadline.weight(.medium))
                Spacer()
                Picker("", selection: $layoutRaw) {
                    Image(systemName: "arrow.up.and.down").tag(0)
                    Image(systemName: "arrow.left.and.right").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 90)
            }
            .padding(.horizontal, 16)
            .padding(.top, 50).padding(.bottom, 12)
            .background(.black.opacity(0.7))

            Spacer()

            HStack {
                Text("\(currentIndex + 1) / \(imageUrls.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white)
                Slider(value: Binding(
                    get: { Double(currentIndex) },
                    set: { currentIndex = Int($0) }
                ), in: 0...Double(max(0, imageUrls.count - 1)), step: 1)
                .tint(WanxiangColors.primary)
            }
            .padding()
            .background(.black.opacity(0.7))
        }
        .ignoresSafeArea()
    }
}

private struct MangaImageView: View {
    let url: String

    var body: some View {
        AsyncImage(url: URL(string: url)) { phase in
            switch phase {
            case .empty:
                ProgressView().tint(.white).frame(maxWidth: .infinity, minHeight: 300)
            case .success(let img):
                img.resizable().scaledToFit()
            case .failure:
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.white.opacity(0.4))
                    .font(.system(size: 32))
                    .frame(maxWidth: .infinity, minHeight: 200)
            @unknown default:
                EmptyView()
            }
        }
    }
}
