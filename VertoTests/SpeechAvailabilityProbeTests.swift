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
import Speech
import XCTest
@testable import Verto

/// 诊断探针（临时）：打印当前运行环境（模拟器/真机）各识别路径的真实可用性。
final class SpeechAvailabilityProbeTests: XCTestCase {
    func testProbeSpeechAvailability() async throws {
        var report: [String] = []
#if targetEnvironment(simulator)
        report.append("ENV: simulator")
#else
        report.append("ENV: device")
#endif
        if #available(iOS 26.0, *) {
            report.append("SpeechTranscriber.isAvailable = \(SpeechTranscriber.isAvailable)")
            let supported = await SpeechTranscriber.supportedLocales
            report.append("SpeechTranscriber.supportedLocales(\(supported.count)) = \(supported.map { $0.identifier(.bcp47) }.sorted().joined(separator: ","))")
            let installed = await SpeechTranscriber.installedLocales
            report.append("SpeechTranscriber.installedLocales = \(installed.map { $0.identifier(.bcp47) }.joined(separator: ","))")
            let zh = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN"))
            let en = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
            report.append("supportedLocale(zh-CN) = \(zh?.identifier(.bcp47) ?? "nil"), (en-US) = \(en?.identifier(.bcp47) ?? "nil")")
            report.append("AssetInventory.reservedLocales = \(await AssetInventory.reservedLocales.map { $0.identifier(.bcp47) }.joined(separator: ","))")
        } else {
            report.append("iOS < 26, no SpeechTranscriber")
        }

        for id in ["en-US", "zh-CN"] {
            if let recognizer = SFSpeechRecognizer(locale: Locale(identifier: id)) {
                report.append("SFSpeechRecognizer(\(id)): isAvailable=\(recognizer.isAvailable) supportsOnDevice=\(recognizer.supportsOnDeviceRecognition)")
            } else {
                report.append("SFSpeechRecognizer(\(id)): init returned nil")
            }
        }
        report.append("SFSpeechRecognizer.authorizationStatus = \(SFSpeechRecognizer.authorizationStatus().rawValue) (0=notDetermined 1=denied 2=restricted 3=authorized)")
        report.append("AVAudioApplication.recordPermission = \(AVAudioApplication.shared.recordPermission.rawValue)")

        // 端到端识别探针：用 TTS 合成一段已知语音，分别以端上/服务器模式识别。
        if let audioURL = try? await Self.synthesizeAudio(text: "Good morning", voiceLanguage: "en-US") {
            for onDevice in [true, false] {
                let outcome = await Self.recognizeFile(audioURL, localeID: "en-US", requiresOnDevice: onDevice)
                report.append("recognize(en-US, onDevice=\(onDevice)): \(outcome)")
            }
        } else {
            report.append("TTS synthesis failed for en-US")
        }
        if let audioURL = try? await Self.synthesizeAudio(text: "你好，早上好", voiceLanguage: "zh-CN") {
            let outcome = await Self.recognizeFile(audioURL, localeID: "zh-CN", requiresOnDevice: false)
            report.append("recognize(zh-CN, onDevice=false): \(outcome)")
        } else {
            report.append("TTS synthesis failed for zh-CN")
        }

        let joined = report.joined(separator: "\n")
        print("SPEECH-PROBE-BEGIN\n\(joined)\nSPEECH-PROBE-END")
        // 模拟器进程与宿主共享文件系统：报告落盘供命令行读取。
        try? joined.write(
            toFile: "/private/tmp/speech-availability-probe.txt",
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(true)
    }

    private static func synthesizeAudio(text: String, voiceLanguage: String) async throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("probe-\(voiceLanguage)-\(UUID().uuidString).caf")
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: voiceLanguage)
        var file: AVAudioFile?
        return try await withCheckedThrowingContinuation { continuation in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if file != nil {
                        continuation.resume(returning: url)
                    } else {
                        continuation.resume(throwing: NSError(domain: "probe", code: 1))
                    }
                    file = nil
                    return
                }
                do {
                    if file == nil {
                        file = try AVAudioFile(forWriting: url, settings: pcm.format.settings)
                    }
                    try file?.write(from: pcm)
                } catch {
                    continuation.resume(throwing: error)
                    file = nil
                }
            }
        }
    }

    private static func recognizeFile(_ url: URL, localeID: String, requiresOnDevice: Bool) async -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) else {
            return "recognizer nil"
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = requiresOnDevice
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { continuation in
            let box = ContinuationBox(continuation)
            recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    box.resumeOnce("ERROR: \((error as NSError).domain) \((error as NSError).code) \(error.localizedDescription)")
                } else if let result, result.isFinal {
                    box.resumeOnce("OK: \"\(result.bestTranscription.formattedString)\"")
                }
            }
            Task {
                try? await Task.sleep(for: .seconds(20))
                box.resumeOnce("TIMEOUT after 20s")
            }
        }
    }

    private final class ContinuationBox: @unchecked Sendable {
        private var continuation: CheckedContinuation<String, Never>?
        private let lock = NSLock()

        init(_ continuation: CheckedContinuation<String, Never>) {
            self.continuation = continuation
        }

        func resumeOnce(_ value: String) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value)
        }
    }
}
