import SwiftUI

struct GameGateView: View {
    @AppStorage("wx.game.unlocked") private var unlocked = false
    @EnvironmentObject var appState: AppState

    var body: some View {
        if unlocked {
            mainAppContent
        } else {
            WaterQualityGateView {
                withAnimation(.easeInOut(duration: 0.4)) {
                    unlocked = true
                }
            }
            .task {
                await PromoCodeManager.shared.bootstrap()
            }
        }
    }

    @ViewBuilder
    private var mainAppContent: some View {
        RootView()
            .environmentObject(appState)
    }
}
