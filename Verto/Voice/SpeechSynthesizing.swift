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

@MainActor
protocol SpeechSynthesizing: AnyObject {
    /// 播放完成或被停止时返回。
    func speak(_ text: String, languageCode: String) async
    func stop()
}

/// AVSpeechSynthesizer 包装。语速对齐文字页朗读（默认速率 ×0.92）。
@MainActor
final class SystemSpeechSynthesizer: NSObject, SpeechSynthesizing {
    private let synthesizer = AVSpeechSynthesizer()
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, languageCode: String) async {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
            synthesizer.speak(utterance)
            // 模拟器上 didFinish 偶发不回调，卡住会锁死半双工循环：按文本长度兜底。
            let timeout = min(30, 3 + Double(text.count) * 0.3)
            watchdogTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self, !Task.isCancelled else { return }
                self.synthesizer.stopSpeaking(at: .immediate)
                self.resumeFinishContinuation()
            }
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        resumeFinishContinuation()
    }

    private func resumeFinishContinuation() {
        watchdogTask?.cancel()
        watchdogTask = nil
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

extension SystemSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.resumeFinishContinuation() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in self.resumeFinishContinuation() }
    }
}

/// 耳机（含蓝牙/USB）是否接入，供「仅戴耳机时朗读」判定。
enum AudioRouteMonitor {
    static var headphonesConnected: Bool {
        let headphonePorts: Set<AVAudioSession.Port> = [
            .headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio
        ]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            headphonePorts.contains($0.portType)
        }
    }
}
