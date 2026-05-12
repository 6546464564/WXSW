import SwiftUI

// MARK: - Tile

struct Tile: Identifiable, Equatable {
    let id: UUID
    var value: Int
    var row: Int
    var col: Int
    var merged: Bool = false
    var isNew: Bool = false
}

// MARK: - Game Model

@MainActor
final class Game2048Model: ObservableObject {
    @Published var tiles: [Tile] = []
    @Published var score: Int = 0
    @Published var bestScore: Int = UserDefaults.standard.integer(forKey: "wx.game2048.best")
    @Published var isGameOver = false
    @Published var boardSize: Int = UserDefaults.standard.integer(forKey: "wx.game2048.size").clamped(to: 4...6)
    @Published var bestTile: Int = UserDefaults.standard.integer(forKey: "wx.game2048.bestTile")
    @Published var totalMoves: Int = UserDefaults.standard.integer(forKey: "wx.game2048.totalMoves")
    @Published var totalGames: Int = UserDefaults.standard.integer(forKey: "wx.game2048.totalGames")
    @Published var showStats = false

    private var previousTiles: [Tile] = []
    private var previousScore: Int = 0
    private var canUndo = false

    var size: Int { boardSize }

    init() {
        if boardSize == 0 { boardSize = 4 }
        startNewGame(resetStats: false)
    }

    func startNewGame(resetStats: Bool = false) {
        tiles = []
        score = 0
        isGameOver = false
        canUndo = false
        previousTiles = []
        if !resetStats {
            totalGames += 1
            UserDefaults.standard.set(totalGames, forKey: "wx.game2048.totalGames")
        }
        addRandomTile()
        addRandomTile()
    }

    func changeBoardSize(_ newSize: Int) {
        boardSize = newSize.clamped(to: 4...6)
        UserDefaults.standard.set(boardSize, forKey: "wx.game2048.size")
        startNewGame()
    }

    // MARK: - Grid Helpers

    private func grid() -> [[Int]] {
        var g = Array(repeating: Array(repeating: 0, count: size), count: size)
        for t in tiles { g[t.row][t.col] = t.value }
        return g
    }

    private func emptyPositions() -> [(Int, Int)] {
        let g = grid()
        var empty: [(Int, Int)] = []
        for r in 0..<size {
            for c in 0..<size {
                if g[r][c] == 0 { empty.append((r, c)) }
            }
        }
        return empty
    }

    private func addRandomTile() {
        let empty = emptyPositions()
        guard let pos = empty.randomElement() else { return }
        let value = Int.random(in: 1...10) <= 9 ? 2 : 4
        tiles.append(Tile(id: UUID(), value: value, row: pos.0, col: pos.1, isNew: true))
    }

    // MARK: - Move

    enum Direction { case up, down, left, right }

    func move(_ dir: Direction) {
        saveState()
        var moved = false

        for t in tiles.indices { tiles[t].merged = false; tiles[t].isNew = false }

        switch dir {
        case .left:  moved = moveLeft()
        case .right: moved = moveRight()
        case .up:    moved = moveUp()
        case .down:  moved = moveDown()
        }

        if moved {
            canUndo = true
            totalMoves += 1
            UserDefaults.standard.set(totalMoves, forKey: "wx.game2048.totalMoves")
            addRandomTile()
            updateBest()
            if !canMakeMove() { isGameOver = true }
            hapticFeedback()
        } else {
            canUndo = false
            previousTiles = []
        }
    }

    func undo() {
        guard canUndo else { return }
        tiles = previousTiles
        score = previousScore
        canUndo = false
        isGameOver = false
    }

    private func saveState() {
        previousTiles = tiles
        previousScore = score
    }

    private func updateBest() {
        if score > bestScore {
            bestScore = score
            UserDefaults.standard.set(bestScore, forKey: "wx.game2048.best")
        }
        let maxTile = tiles.map(\.value).max() ?? 0
        if maxTile > bestTile {
            bestTile = maxTile
            UserDefaults.standard.set(bestTile, forKey: "wx.game2048.bestTile")
        }
    }

    // MARK: - Move Logic

    private func moveLeft() -> Bool {
        var changed = false
        for r in 0..<size {
            let row = tiles.filter { $0.row == r }.sorted { $0.col < $1.col }
            var col = 0
            var lastMergedCol = -1
            for tile in row {
                let idx = tiles.firstIndex(where: { $0.id == tile.id })!
                if col > 0,
                   let prev = tiles.first(where: { $0.row == r && $0.col == col - 1 && !$0.merged }),
                   prev.value == tile.value,
                   col - 1 != lastMergedCol {
                    let prevIdx = tiles.firstIndex(where: { $0.id == prev.id })!
                    tiles[prevIdx].value *= 2
                    tiles[prevIdx].merged = true
                    score += tiles[prevIdx].value
                    lastMergedCol = col - 1
                    tiles.remove(at: idx > prevIdx ? idx : tiles.firstIndex(where: { $0.id == tile.id })!)
                    changed = true
                } else {
                    if tiles[idx].col != col { changed = true }
                    tiles[idx].col = col
                    col += 1
                }
            }
        }
        return changed
    }

    private func moveRight() -> Bool {
        var changed = false
        for r in 0..<size {
            let row = tiles.filter { $0.row == r }.sorted { $0.col > $1.col }
            var col = size - 1
            var lastMergedCol = size
            for tile in row {
                let idx = tiles.firstIndex(where: { $0.id == tile.id })!
                if col < size - 1,
                   let prev = tiles.first(where: { $0.row == r && $0.col == col + 1 && !$0.merged }),
                   prev.value == tile.value,
                   col + 1 != lastMergedCol {
                    let prevIdx = tiles.firstIndex(where: { $0.id == prev.id })!
                    tiles[prevIdx].value *= 2
                    tiles[prevIdx].merged = true
                    score += tiles[prevIdx].value
                    lastMergedCol = col + 1
                    tiles.remove(at: tiles.firstIndex(where: { $0.id == tile.id })!)
                    changed = true
                } else {
                    if tiles[idx].col != col { changed = true }
                    tiles[idx].col = col
                    col -= 1
                }
            }
        }
        return changed
    }

    private func moveUp() -> Bool {
        var changed = false
        for c in 0..<size {
            let col = tiles.filter { $0.col == c }.sorted { $0.row < $1.row }
            var row = 0
            var lastMergedRow = -1
            for tile in col {
                let idx = tiles.firstIndex(where: { $0.id == tile.id })!
                if row > 0,
                   let prev = tiles.first(where: { $0.col == c && $0.row == row - 1 && !$0.merged }),
                   prev.value == tile.value,
                   row - 1 != lastMergedRow {
                    let prevIdx = tiles.firstIndex(where: { $0.id == prev.id })!
                    tiles[prevIdx].value *= 2
                    tiles[prevIdx].merged = true
                    score += tiles[prevIdx].value
                    lastMergedRow = row - 1
                    tiles.remove(at: tiles.firstIndex(where: { $0.id == tile.id })!)
                    changed = true
                } else {
                    if tiles[idx].row != row { changed = true }
                    tiles[idx].row = row
                    row += 1
                }
            }
        }
        return changed
    }

    private func moveDown() -> Bool {
        var changed = false
        for c in 0..<size {
            let col = tiles.filter { $0.col == c }.sorted { $0.row > $1.row }
            var row = size - 1
            var lastMergedRow = size
            for tile in col {
                let idx = tiles.firstIndex(where: { $0.id == tile.id })!
                if row < size - 1,
                   let prev = tiles.first(where: { $0.col == c && $0.row == row + 1 && !$0.merged }),
                   prev.value == tile.value,
                   row + 1 != lastMergedRow {
                    let prevIdx = tiles.firstIndex(where: { $0.id == prev.id })!
                    tiles[prevIdx].value *= 2
                    tiles[prevIdx].merged = true
                    score += tiles[prevIdx].value
                    lastMergedRow = row + 1
                    tiles.remove(at: tiles.firstIndex(where: { $0.id == tile.id })!)
                    changed = true
                } else {
                    if tiles[idx].row != row { changed = true }
                    tiles[idx].row = row
                    row -= 1
                }
            }
        }
        return changed
    }

    private func canMakeMove() -> Bool {
        if tiles.count < size * size { return true }
        let g = grid()
        for r in 0..<size {
            for c in 0..<size {
                if c + 1 < size && g[r][c] == g[r][c + 1] { return true }
                if r + 1 < size && g[r][c] == g[r + 1][c] { return true }
            }
        }
        return false
    }

    private func hapticFeedback() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.impactOccurred()
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Theme

private struct TileTheme {
    let bg: Color
    let fg: Color
    let glow: Bool

    static func theme(for value: Int) -> TileTheme {
        switch value {
        case 0:    return TileTheme(bg: Color(.systemGray5), fg: .clear, glow: false)
        case 2:    return TileTheme(bg: Color(red: 0.93, green: 0.89, blue: 0.85), fg: Color(red: 0.47, green: 0.43, blue: 0.40), glow: false)
        case 4:    return TileTheme(bg: Color(red: 0.93, green: 0.88, blue: 0.78), fg: Color(red: 0.47, green: 0.43, blue: 0.40), glow: false)
        case 8:    return TileTheme(bg: Color(red: 0.95, green: 0.69, blue: 0.47), fg: .white, glow: false)
        case 16:   return TileTheme(bg: Color(red: 0.96, green: 0.58, blue: 0.39), fg: .white, glow: false)
        case 32:   return TileTheme(bg: Color(red: 0.96, green: 0.49, blue: 0.37), fg: .white, glow: false)
        case 64:   return TileTheme(bg: Color(red: 0.96, green: 0.37, blue: 0.23), fg: .white, glow: false)
        case 128:  return TileTheme(bg: Color(red: 0.93, green: 0.81, blue: 0.45), fg: .white, glow: true)
        case 256:  return TileTheme(bg: Color(red: 0.93, green: 0.80, blue: 0.38), fg: .white, glow: true)
        case 512:  return TileTheme(bg: Color(red: 0.93, green: 0.78, blue: 0.31), fg: .white, glow: true)
        case 1024: return TileTheme(bg: Color(red: 0.93, green: 0.77, blue: 0.25), fg: .white, glow: true)
        case 2048: return TileTheme(bg: Color(red: 0.93, green: 0.76, blue: 0.18), fg: .white, glow: true)
        default:   return TileTheme(bg: Color(red: 0.24, green: 0.23, blue: 0.20), fg: .white, glow: true)
        }
    }
}

private func tileFontSize(_ value: Int, tileSize: CGFloat) -> CGFloat {
    let base = tileSize * 0.42
    switch value {
    case 0..<100:      return base
    case 100..<1000:   return base * 0.82
    case 1000..<10000: return base * 0.66
    default:           return base * 0.55
    }
}

// MARK: - Tile View

private struct TileView: View {
    let tile: Tile
    let tileSize: CGFloat

    var body: some View {
        let theme = TileTheme.theme(for: tile.value)
        ZStack {
            RoundedRectangle(cornerRadius: tileSize * 0.08)
                .fill(theme.bg)
                .shadow(
                    color: theme.glow ? theme.bg.opacity(0.6) : .clear,
                    radius: theme.glow ? 8 : 0
                )

            if tile.value > 0 {
                Text("\(tile.value)")
                    .font(.system(size: tileFontSize(tile.value, tileSize: tileSize), weight: .black, design: .rounded))
                    .foregroundColor(theme.fg)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
            }
        }
        .frame(width: tileSize, height: tileSize)
        .scaleEffect(tile.isNew ? 0.2 : (tile.merged ? 1.15 : 1.0))
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: tile.isNew)
        .animation(.spring(response: 0.2, dampingFraction: 0.5), value: tile.merged)
    }
}

// MARK: - Game View

struct Game2048View: View {
    @StateObject private var game = Game2048Model()
    @State private var codeInput = ""
    @State private var showCodeField = false
    @FocusState private var codeFocused: Bool
    let onUnlock: () -> Void

    private let spacing: CGFloat = 6
    private let boardColor = Color(red: 0.73, green: 0.68, blue: 0.63)

    var body: some View {
        GeometryReader { geo in
            let isCompact = geo.size.height < 700
            VStack(spacing: isCompact ? 10 : 16) {
                header(isCompact: isCompact)
                toolbar
                board(in: geo)
                    .gesture(dragGesture)
                if game.isGameOver {
                    gameOverCard
                }
                Spacer(minLength: 0)
                codeEntryArea
            }
            .padding(.horizontal, 16)
            .padding(.top, isCompact ? 4 : 12)
        }
        .background(Color(red: 0.98, green: 0.97, blue: 0.94).ignoresSafeArea())
        .sheet(isPresented: $game.showStats) { statsSheet }
    }

    // MARK: - Header

    private func header(isCompact: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("2048")
                    .font(.system(size: isCompact ? 36 : 48, weight: .black, design: .rounded))
                    .foregroundColor(Color(red: 0.47, green: 0.43, blue: 0.40))
                Text("合并方块，挑战高分！")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(.secondary)
            }
            Spacer()
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    scoreBox(label: "分数", value: game.score)
                    scoreBox(label: "最高", value: game.bestScore)
                }
            }
        }
    }

    private func scoreBox(label: String, value: Int) -> some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundColor(Color(red: 0.93, green: 0.89, blue: 0.85))
                .textCase(.uppercase)
            Text("\(value)")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .contentTransition(.numericText())
        }
        .frame(minWidth: 56)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(Color(red: 0.73, green: 0.68, blue: 0.63))
        .cornerRadius(6)
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: { game.startNewGame() }) {
                Label("新游戏", systemImage: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .buttonStyle(ToolbarButtonStyle())

            Button(action: { game.undo() }) {
                Label("撤销", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .buttonStyle(ToolbarButtonStyle())

            Spacer()

            Menu {
                ForEach([4, 5, 6], id: \.self) { s in
                    Button("\(s) × \(s)") { game.changeBoardSize(s) }
                }
            } label: {
                Label("\(game.size)×\(game.size)", systemImage: "square.grid.3x3")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .buttonStyle(ToolbarButtonStyle())

            Button(action: { game.showStats = true }) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(ToolbarButtonStyle())
        }
    }

    // MARK: - Board

    private func board(in geo: GeometryProxy) -> some View {
        let maxSide = min(geo.size.width - 32, geo.size.height * 0.52)
        let side = max(200, maxSide)
        let tileSize = (side - spacing * CGFloat(game.size + 1)) / CGFloat(game.size)

        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(boardColor)

            // Empty cells
            ForEach(0..<game.size, id: \.self) { r in
                ForEach(0..<game.size, id: \.self) { c in
                    RoundedRectangle(cornerRadius: tileSize * 0.08)
                        .fill(Color(.systemGray5).opacity(0.6))
                        .frame(width: tileSize, height: tileSize)
                        .position(
                            x: spacing + tileSize / 2 + CGFloat(c) * (tileSize + spacing),
                            y: spacing + tileSize / 2 + CGFloat(r) * (tileSize + spacing)
                        )
                }
            }

            // Tiles
            ForEach(game.tiles) { tile in
                TileView(tile: tile, tileSize: tileSize)
                    .position(
                        x: spacing + tileSize / 2 + CGFloat(tile.col) * (tileSize + spacing),
                        y: spacing + tileSize / 2 + CGFloat(tile.row) * (tileSize + spacing)
                    )
                    .animation(.spring(response: 0.15, dampingFraction: 0.75), value: tile.row)
                    .animation(.spring(response: 0.15, dampingFraction: 0.75), value: tile.col)
            }
        }
        .frame(width: side, height: side)
    }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                withAnimation {
                    if abs(dx) > abs(dy) {
                        game.move(dx > 0 ? .right : .left)
                    } else {
                        game.move(dy > 0 ? .down : .up)
                    }
                }
            }
    }

    // MARK: - Game Over

    private var gameOverCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text("游戏结束")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(Color(red: 0.47, green: 0.43, blue: 0.40))
            HStack(spacing: 20) {
                VStack(spacing: 2) {
                    Text("分数")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(game.score)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                }
                VStack(spacing: 2) {
                    Text("最大方块")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(game.tiles.map(\.value).max() ?? 0)")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(.orange)
                }
            }
            HStack(spacing: 12) {
                Button("撤销") { withAnimation { game.undo() } }
                    .buttonStyle(ToolbarButtonStyle())
                Button("再来一局") { withAnimation { game.startNewGame() } }
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.orange)
                    .cornerRadius(8)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Stats Sheet

    private var statsSheet: some View {
        NavigationView {
            List {
                Section("游戏统计") {
                    statRow(icon: "trophy.fill", label: "最高分", value: "\(game.bestScore)", color: .orange)
                    statRow(icon: "square.fill", label: "最大方块", value: "\(game.bestTile)", color: .purple)
                    statRow(icon: "hand.draw.fill", label: "总步数", value: "\(game.totalMoves)", color: .blue)
                    statRow(icon: "gamecontroller.fill", label: "总局数", value: "\(game.totalGames)", color: .green)
                }
            }
            .navigationTitle("统计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { game.showStats = false }
                }
            }
        }
    }

    private func statRow(icon: String, label: String, value: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 28)
            Text(label)
            Spacer()
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(color)
        }
    }

    // MARK: - Secret Code

    private var codeEntryArea: some View {
        VStack(spacing: 8) {
            Button(action: { withAnimation(.spring(response: 0.3)) { showCodeField.toggle() } }) {
                HStack(spacing: 4) {
                    Image(systemName: "gearshape")
                    Text("设置")
                }
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            }

            if showCodeField {
                HStack(spacing: 8) {
                    TextField("输入激活码", text: $codeInput)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        .focused($codeFocused)

                    Button("确认") {
                        if codeInput == "8888" {
                            UserDefaults.standard.set(true, forKey: "wx.game.unlocked")
                            onUnlock()
                        } else {
                            codeInput = ""
                            let gen = UINotificationFeedbackGenerator()
                            gen.notificationOccurred(.error)
                        }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.blue)
                    .cornerRadius(8)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Toolbar Button Style

private struct ToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(Color(red: 0.47, green: 0.43, blue: 0.40))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(red: 0.93, green: 0.89, blue: 0.85))
            .cornerRadius(6)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
