//
//  VolumeKeyHandler.swift
//  万象书屋 iOS · 音量键翻页
//
//  对应 Android: ReadBookActivity.onKeyDown(VOLUME_UP/DOWN)
//
//  iOS 实现策略:
//   - 不能直接监听硬件音量键事件 (Apple 限制),但可以 KVO `AVAudioSession.outputVolume`
//     当 outputVolume 变化时, 反推用户按了音量键 (volume + 或 -)
//   - 把音量"虚拟"复位到 0.5 (避免到顶 0.0/1.0 后再按无变化检测不到)
//   - 触发 onPrev / onNext callback
//
//  注意: 这种实现会偶尔被系统 lock screen / 蓝牙耳机干扰. 真机最佳, 模拟器没硬件音量键测不出.
//

import Foundation
import AVFoundation
import UIKit
import MediaPlayer

@MainActor
public final class VolumeKeyHandler: NSObject {

    public static let shared = VolumeKeyHandler()

    private var session: AVAudioSession { AVAudioSession.sharedInstance() }
    private var observation: NSKeyValueObservation? = nil
    private var onVolumeUp: (() -> Void)? = nil
    private var onVolumeDown: (() -> Void)? = nil
    private var lastVolume: Float = 0.5
    private var ignoreNext: Int = 0   // setupVolumeView 触发的虚拟音量变化要忽略
    private var hiddenVolumeView: MPVolumeView? = nil

    public var isEnabled: Bool = false

    public func enable(onUp: @escaping () -> Void, onDown: @escaping () -> Void) {
        guard !isEnabled else { return }
        isEnabled = true
        self.onVolumeUp = onUp
        self.onVolumeDown = onDown

        // 万象书屋: 必须 active 一个 audio session 才能监听 outputVolume
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)

        // 把当前音量记下来作为基准
        lastVolume = session.outputVolume

        observation = session.observe(\.outputVolume, options: [.new, .old]) { [weak self] _, change in
            guard let self else { return }
            let new = change.newValue ?? 0
            let old = change.oldValue ?? 0
            Task { @MainActor in
                await self.handleVolumeChange(old: old, new: new)
            }
        }

        // 隐藏一个 MPVolumeView, 用来"重置音量到 0.5"避免到顶
        let v = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 100, height: 100))
        v.isHidden = false   // 必须 visible 才能 work
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.addSubview(v)
        self.hiddenVolumeView = v
    }

    public func disable() {
        guard isEnabled else { return }
        isEnabled = false
        observation?.invalidate()
        observation = nil
        onVolumeUp = nil
        onVolumeDown = nil
        hiddenVolumeView?.removeFromSuperview()
        hiddenVolumeView = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handleVolumeChange(old: Float, new: Float) async {
        if ignoreNext > 0 {
            ignoreNext -= 1
            lastVolume = new
            return
        }
        if abs(new - old) < 0.001 { return }
        if new > old {
            onVolumeUp?()
        } else {
            onVolumeDown?()
        }
        lastVolume = new
        // 万象书屋: 把音量虚拟复位 → 防止到顶之后按音量没事件
        if new <= 0.05 || new >= 0.95 {
            ignoreNext += 1
            await setSystemVolume(0.5)
        }
    }

    /// 通过 MPVolumeView 内部的 slider 重置系统音量 (无视觉)
    private func setSystemVolume(_ volume: Float) async {
        guard let view = hiddenVolumeView else { return }
        guard let slider = view.subviews.compactMap({ $0 as? UISlider }).first else { return }
        // 异步 set 避免 UIView 同步触发 KVO 死循环
        try? await Task.sleep(nanoseconds: 100_000_000)
        slider.value = volume
    }
}
