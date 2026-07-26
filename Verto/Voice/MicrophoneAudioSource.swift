//
//  Copyright 2026 Yspritan
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import AVFoundation
import Accelerate
import os

/// AVAudioEngine 麦克风采集，识别引擎共用。tap 回调在实时音频线程——
/// 只触碰局部捕获量（continuation、锁与 vDSP 计算），buffer 与线性 RMS 电平
/// 经 AsyncStream 过桥给消费方。支持挂起（TTS 播放/句间间隙丢弃 buffer，
/// 引擎与音频会话保持活跃，避免逐句 setActive 循环的启动延迟）。
final class MicrophoneAudioSource: @unchecked Sendable {
    struct Chunk: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        /// 线性 RMS（人声常 <0.15），静音判定阈值见 VoiceTuning。
        let level: Float
    }

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<Chunk>.Continuation?
    private var configurationObserver: NSObjectProtocol?
    private(set) var inputFormat: AVAudioFormat?
    private let suspended = OSAllocatedUnfairLock(initialState: false)

    var isRunning: Bool { continuation != nil }

    /// 挂起 = tap 丢弃 buffer（半双工：TTS 播放与句间间隙不送识别）。
    func setSuspended(_ value: Bool) {
        suspended.withLock { $0 = value }
    }

    func start() throws -> AsyncStream<Chunk> {
        let session = AVAudioSession.sharedInstance()
        do {
            // 半双工模型：TTS 播放期间麦克风不在运行，不需要 .voiceChat 的回声消除，
            // .default 模式保 TTS 音质。
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true)
        } catch {
            throw SpeechTranscriptionError.audioSessionFailure
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw SpeechTranscriptionError.audioSessionFailure
        }
        inputFormat = format

        let (stream, continuation) = AsyncStream.makeStream(
            of: Chunk.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        self.continuation = continuation

        setSuspended(false)
        let suspended = self.suspended
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard !suspended.withLock({ $0 }) else { return }
            continuation.yield(Chunk(buffer: buffer, level: Self.rmsLevel(of: buffer)))
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.continuation = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw SpeechTranscriptionError.audioSessionFailure
        }

        // 路由变化（插拔耳机等）会停转 engine。输入硬件格式可能随之改变
        // （蓝牙 HFP 麦克风 16/24kHz），带旧格式 tap 盲目重启会抛 NSException，
        // 旧格式的下游 AVAudioConverter 也会失效——格式变了就结束本段，
        // 让上层用新格式重建整条链；格式没变才原格式重装 tap 续采。
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.continuation != nil, !self.engine.isRunning else { return }
            let input = self.engine.inputNode
            input.removeTap(onBus: 0)
            let freshFormat = input.outputFormat(forBus: 0)
            let formatUnchanged = self.inputFormat.map {
                $0.sampleRate == freshFormat.sampleRate && $0.channelCount == freshFormat.channelCount
            } ?? false
            guard formatUnchanged, freshFormat.sampleRate > 0 else {
                self.stop()
                return
            }
            let suspended = self.suspended
            input.installTap(onBus: 0, bufferSize: 4096, format: freshFormat) { buffer, _ in
                guard !suspended.withLock({ $0 }) else { return }
                continuation.yield(Chunk(buffer: buffer, level: Self.rmsLevel(of: buffer)))
            }
            self.engine.prepare()
            if (try? self.engine.start()) == nil {
                self.stop()
            }
        }
        return stream
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        guard continuation != nil else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(data, 1, &rms, vDSP_Length(buffer.frameLength))
        return min(max(rms, 0), 1)
    }
}
