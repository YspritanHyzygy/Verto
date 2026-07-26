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

import Foundation

#if DEBUG
/// UI 测试用：不真正播放语音，立即返回，保证脚本化流程确定性。
@MainActor
final class SilentSpeechSynthesizer: SpeechSynthesizing {
    func speak(_ text: String, languageCode: String) async {}
    func stop() {}
}

/// UI 测试用的脚本化识别：--uitest-canned-speech 注入，零真实音频/权限，
/// 输出固定 volatile → final 序列；final 文本与 CannedTranslationService 的
/// 固定译文表对齐，保证断言稳定。自动检测模式（多语言）下按段轮换语言，
/// 演示双语无缝对话；同一语言多次开始按脚本轮换。
@MainActor
final class CannedSpeechTranscriptionService: VoiceTranscriptionService {
    private struct Script {
        let volatiles: [String]
        let final: String
    }

    private var continuation: AsyncThrowingStream<SpeechTranscriptionEvent, Error>.Continuation?
    private var scriptTask: Task<Void, Never>?
    private var pendingFinal: (text: String, language: Language)?
    private var utteranceCounts: [String: Int] = [:]
    private var totalUtterances = 0

    func prepare(
        for languages: [Language],
        downloadProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        downloadProgress(1)
    }

    func startUtterance(
        languages: [Language]
    ) async throws -> AsyncThrowingStream<SpeechTranscriptionEvent, Error> {
        // 自动检测模式：按总段数在候选语言间轮换，模拟双方轮流讲话。
        let language = languages.isEmpty
            ? Language.english
            : languages[totalUtterances % languages.count]
        let index = utteranceCounts[language.code, default: 0]
        utteranceCounts[language.code] = index + 1
        let script = Self.script(for: language.code, index: index)
        // 首段快速开播；自动续听的后续段先留出可观察的「正在聆听」窗口，
        // 模拟真实对话的句间停顿，也让 UI 断言与点按有确定性落点。
        let leadIn: Duration = totalUtterances == 0 ? .milliseconds(120) : .milliseconds(1500)
        totalUtterances += 1

        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SpeechTranscriptionEvent.self)
        self.continuation = continuation
        pendingFinal = (script.final, language)
        scriptTask = Task { [weak self] in
            try? await Task.sleep(for: leadIn)
            guard !Task.isCancelled else { return }
            for volatile in script.volatiles {
                try? await Task.sleep(for: .milliseconds(90))
                guard !Task.isCancelled else { return }
                continuation.yield(.audioLevel(0.6))
                continuation.yield(.volatile(volatile, language))
            }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.emitFinal()
        }
        return stream
    }

    func finishUtterance() async {
        emitFinal()
    }

    func cancel() async {
        scriptTask?.cancel()
        scriptTask = nil
        pendingFinal = nil
        continuation?.finish()
        continuation = nil
    }

    private func emitFinal() {
        guard let continuation, let pendingFinal else { return }
        self.pendingFinal = nil
        scriptTask?.cancel()
        scriptTask = nil
        continuation.yield(.final(pendingFinal.text, pendingFinal.language))
        continuation.finish()
        self.continuation = nil
    }

    private static func script(for code: String, index: Int) -> Script {
        let scripts: [Script]
        switch code {
        case "en":
            scripts = [
                Script(volatiles: ["Good", "Good morn"], final: "Good morning"),
                Script(volatiles: ["Thank", "Thank you"], final: "Thank you")
            ]
        case "zh-Hans":
            scripts = [
                Script(volatiles: ["你"], final: "你好"),
                Script(volatiles: ["谢谢"], final: "谢谢你的款待。")
            ]
        default:
            scripts = [Script(volatiles: ["…"], final: "Canned \(code)")]
        }
        return scripts[index % scripts.count]
    }
}
#endif
