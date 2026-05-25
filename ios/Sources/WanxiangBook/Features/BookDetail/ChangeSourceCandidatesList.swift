//
//  ChangeSourceCandidatesList.swift
//  万象书屋 iOS · 换源候选列表 (整书 / 本章换源共用)
//
//  ScrollView + LazyVStack 替代 List, 避免 duplicate ForEach id 与 sheet 内 graph mutation 闪退.
//

import SwiftUI

struct ChangeSourceCandidatesList<Row: View>: View {

    let display: [ChangeSourceViewModel.Candidate]
    let header: String
    let currentOrigin: String?
    let scrollToken: UUID
    let jumpEdgeToken: ChangeSourceJumpToken
    @ViewBuilder let rowContent: (ChangeSourceViewModel.Candidate) -> Row

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(display, id: \.stableId) { item in
                            rowContent(item)
                                .id(item.stableId)
                        }
                    } header: {
                        Text(header)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color(.systemBackground))
                    }
                }
            }
            .onChange(of: scrollToken) { _ in
                guard let cur = currentOrigin,
                      let hit = display.first(where: { $0.book.origin == cur }) else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(hit.stableId, anchor: .center)
                }
            }
            .onChange(of: jumpEdgeToken) { tok in
                let ids = display.map(\.stableId)
                guard !ids.isEmpty else { return }
                withAnimation {
                    switch tok.kind {
                    case .top:    proxy.scrollTo(ids[0], anchor: .top)
                    case .bottom: proxy.scrollTo(ids[ids.count - 1], anchor: .bottom)
                    case .none:   break
                    }
                }
            }
        }
    }
}

struct ChangeSourceJumpToken: Equatable {
    enum Kind { case none, top, bottom }
    let kind: Kind
    let id = UUID()
    static func == (l: ChangeSourceJumpToken, r: ChangeSourceJumpToken) -> Bool { l.id == r.id }
}
