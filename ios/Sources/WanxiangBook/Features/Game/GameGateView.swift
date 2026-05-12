import SwiftUI

struct GameGateView: View {
    @State private var unlocked = UserDefaults.standard.bool(forKey: "wx.game.unlocked")
    @EnvironmentObject var appState: AppState

    var body: some View {
        if unlocked {
            mainAppContent
        } else {
            Game2048View {
                withAnimation(.easeInOut(duration: 0.4)) {
                    unlocked = true
                }
            }
        }
    }

    @ViewBuilder
    private var mainAppContent: some View {
        RootView()
            .environmentObject(appState)
    }
}
