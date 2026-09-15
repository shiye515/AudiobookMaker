//
//  AudioPlaybackService.swift
//  abm
//
//  单实例互斥音频播放（章节试听 / 音色中心样本），供常驻播放条与试听控件共用。
//

import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioPlaybackService: NSObject, AVAudioPlayerDelegate {

    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var rate: Float = 1.0 {
        didSet { player?.enableRate = true; player?.rate = rate }
    }
    var volume: Float = 1.0 {
        didSet { player?.volume = volume }
    }
    /// 当前播放的上下文标识（如 "bookID/chapterID" 或 "voice/longmiao_v3.mp3"）
    private(set) var contextID: String?
    /// 播放条展示用元数据（主标题/副标题/关联书籍），由播放方在 play() 时传入，stop 时清空
    private(set) var displayTitle: String?
    private(set) var displaySubtitle: String?
    private(set) var currentBookID: String?

    /// 内部播放器与定时器不参与 Observation 追踪，避免实例替换/高频更新产生无意义事件
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    /// 播放/恢复；同一 context 再次调用 = 重新播放。title/subtitle/bookID 供播放条展示与溯源。
    func play(url: URL, contextID: String, title: String? = nil, subtitle: String? = nil, bookID: String? = nil) {
        OutputManager.appendLog("[player] play() 被调用 | contextID=\(contextID) | url=\(url.path)")

        // 检查物理文件
        let fileManager = FileManager.default
        let fileExists = fileManager.fileExists(atPath: url.path)
        let isReadable = fileManager.isReadableFile(atPath: url.path)
        var fileSizeStr = "未知"
        if let attr = try? fileManager.attributesOfItem(atPath: url.path),
           let size = attr[.size] as? Int64 {
            fileSizeStr = "\(size) 字节"
        }
        OutputManager.appendLog("[player] 文件检查: 存在=\(fileExists), 可读=\(isReadable), 大小=\(fileSizeStr)")

        if isPlaying || player != nil {
            OutputManager.appendLog("[player] 检测到已有播放正在运行 [contextID=\(self.contextID ?? "nil")], 执行 stop() 清理旧状态")
        }
        stop()

        guard fileExists else {
            OutputManager.appendLog("[player] ❌ 目标音频文件物理不存在，放弃播放: \(url.path)")
            return
        }

        let newPlayer: AVAudioPlayer
        do {
            newPlayer = try AVAudioPlayer(contentsOf: url)
        } catch {
            OutputManager.appendLog("[player] ❌ AVAudioPlayer(contentsOf:) 初始化抛出异常: \(error.localizedDescription) | 详情: \(error)")
            return
        }

        self.player = newPlayer
        newPlayer.delegate = self
        newPlayer.enableRate = true
        newPlayer.rate = rate
        newPlayer.volume = volume

        let prepared = newPlayer.prepareToPlay()
        let started = newPlayer.play()

        isPlaying = started
        duration = newPlayer.duration
        currentTime = 0
        self.contextID = contextID
        self.displayTitle = title
        self.displaySubtitle = subtitle
        self.currentBookID = bookID

        OutputManager.appendLog("[player] 播放器启动: prepareToPlay=\(prepared), play()=\(started), duration=\(newPlayer.duration)s, channels=\(newPlayer.numberOfChannels), isPlaying=\(newPlayer.isPlaying), volume=\(newPlayer.volume), rate=\(newPlayer.rate)")

        if started {
            startTicker()
        } else {
            OutputManager.appendLog("[player] ⚠️ AVAudioPlayer.play() 返回了 false，未能成功启动播放！")
        }
    }

    func togglePause() {
        guard let player else {
            OutputManager.appendLog("[player] togglePause() 忽略: player 为 nil")
            return
        }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            OutputManager.appendLog("[player] togglePause() -> 暂停 (currentTime=\(player.currentTime)s)")
        } else {
            let started = player.play()
            isPlaying = started
            OutputManager.appendLog("[player] togglePause() -> 恢复播放结果=\(started) (currentTime=\(player.currentTime)s)")
        }
    }

    func pause() {
        guard let player else {
            OutputManager.appendLog("[player] pause() 忽略: player 为 nil")
            return
        }
        player.pause()
        isPlaying = false
        OutputManager.appendLog("[player] pause() 执行完毕 (currentTime=\(player.currentTime)s)")
    }

    func stop() {
        if player != nil || isPlaying {
            OutputManager.appendLog("[player] stop() 执行: 之前 isPlaying=\(isPlaying), contextID=\(contextID ?? "nil"), currentTime=\(currentTime)s")
        }
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        contextID = nil
        displayTitle = nil
        displaySubtitle = nil
        currentBookID = nil
    }

    func seek(to seconds: Double) {
        guard let player else {
            OutputManager.appendLog("[player] seek(to: \(seconds)) 忽略: player 为 nil")
            return
        }
        let target = max(0, min(seconds, player.duration))
        player.currentTime = target
        currentTime = player.currentTime
        OutputManager.appendLog("[player] seek 到 \(currentTime)s / \(player.duration)s")
    }

    func skip(by seconds: Double) {
        seek(to: currentTime + seconds)
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let player = self.player {
                    self.currentTime = player.currentTime
                    if !player.isPlaying && self.isPlaying && player.currentTime > 0 {
                        // 暂停由 delegate/调用方负责
                    }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        OutputManager.appendLog("[player] 委托通知: audioPlayerDidFinishPlaying, successfully=\(flag), currentTime=\(player.currentTime)s, duration=\(player.duration)s")
        // 播完即结束会话，播放条随之隐藏
        Task { @MainActor in
            self.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let errDesc = error?.localizedDescription ?? "无具体信息"
        OutputManager.appendLog("[player] ❌ 委托通知: audioPlayerDecodeErrorDidOccur, 解码错误: \(errDesc) (Error: \(String(describing: error)))")
        // 解码失败的会话不可恢复，同样结束会话避免播放条悬挂
        Task { @MainActor in
            self.stop()
        }
    }
}
