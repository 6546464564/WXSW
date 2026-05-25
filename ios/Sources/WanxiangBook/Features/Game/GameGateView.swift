import SwiftUI

private extension Notification.Name {
    static let wxGameRelocked = Notification.Name("wx.game.relocked")
}

struct GameGateView: View {
    @State private var unlocked: Bool = UserDefaults.standard.bool(forKey: "wx.game.unlocked")
    @EnvironmentObject var appState: AppState

    var body: some View {
        if unlocked {
            mainAppContent
                .onReceive(NotificationCenter.default.publisher(for: .wxGameRelocked)) { _ in
                    withAnimation(.easeInOut(duration: 0.4)) {
                        unlocked = false
                    }
                }
        } else {
            WaterQualityGateView {
                UserDefaults.standard.set(true, forKey: "wx.game.unlocked")
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
