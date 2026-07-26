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
import Foundation
import NaturalLanguage

/// 语音识别事件。一次识别 = 一段话（utterance-per-session 半双工模型）：
/// startUtterance 返回的事件流持续到 finishUtterance / cancel / 出错。
/// 多语言（自动检测）模式下，事件附带当前最优假设所属的语言。
enum SpeechTranscriptionEvent: Equatable, Sendable {
    /// 易变假设：整段替换之前的 volatile 文本。
    case volatile(String, Language)
    /// 一段话定稿。收到后 volatile 缓冲即作废。
    case final(String, Language)
    /// 0...1 输入电平，驱动波形，已节流。
    case audioLevel(Float)
}

enum SpeechTranscriptionError: LocalizedError, Equatable {
    case microphoneDenied
    case speechAuthorizationDenied
    case recognizerUnavailable
    case assetUnavailable
    case audioSessionFailure
    case recognitionFailed
    /// 模拟器上系统本地识别器无法初始化（kLSRErrorDomain 300，苹果层限制）。
    case unsupportedInSimulator

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: String(localized: "未获得麦克风权限，请在系统设置中开启")
        case .speechAuthorizationDenied: String(localized: "未获得语音识别权限，请在系统设置中开启")
        case .recognizerUnavailable: String(localized: "当前设备暂不支持识别这种语言")
        case .assetUnavailable: String(localized: "语音识别模型未就绪，请联网后重试")
        case .audioSessionFailure: String(localized: "麦克风启动失败，请重试")
        case .recognitionFailed: String(localized: "语音识别出错，请重试")
        case .unsupportedInSimulator: String(localized: "模拟器暂不支持这种语言的识别，请在真机上测试")
        }
    }
}

@MainActor
protocol VoiceTranscriptionService: AnyObject {
    /// 权限 + 语言资产准备。首次调用可能弹系统权限框或触发语言模型下载；
    /// 下载进度经 downloadProgress 回调（0...1）。抛 SpeechTranscriptionError。
    func prepare(
        for languages: [Language],
        downloadProgress: @escaping @MainActor (Double) -> Void
    ) async throws
    /// 开始识别一段话。传入多个语言即自动检测模式（每个语言一条识别轨并行，
    /// 按语言概率+置信度选胜者）。同一 service 同时只允许一段进行中。
    func startUtterance(
        languages: [Language]
    ) async throws -> AsyncThrowingStream<SpeechTranscriptionEvent, Error>
    /// 定稿：剩余 volatile 以 .final 事件送出后流结束。
    /// 持久会话实现只切分不停链，下一段零启动成本。
    func finishUtterance() async
    /// 立即丢弃，不产生 final，流直接结束。
    func cancel() async
    /// TTS 播放期间挂起输入（丢弃 buffer 防回采自转写），识别链保持存活。
    func setInputSuspended(_ suspended: Bool)
}

extension VoiceTranscriptionService {
    func setInputSuspended(_ suspended: Bool) {}
}

/// 多轨识别的胜者判定：加权文本量 + 无约束语言概率 + 识别置信度。
/// zh/en 这类文字系统迥异的语言对几乎立判；同文字系语言对主要靠置信度，
/// volatile 期（置信度普遍为 0）的判定是启发式，final 重打分才是权威。
enum TranscriptionLanguageScorer {
    static func score(
        text: String,
        language: Language,
        candidates: [Language],
        confidence: Double? = nil
    ) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        // 文本越长证据越足；CJK 单字信息量远高于拉丁字母，
        // 加权避免「英文轨的同音垃圾字符更多」系统性压过中文轨。
        let weightedLength = trimmed.reduce(0.0) { partial, character in
            partial + (character.unicodeScalars.contains { (0x3040...0x9FFF).contains($0.value) } ? 2.5 : 1)
        }
        var score = min(weightedLength, 12) * 0.02
        // 不加候选约束：错误轨的「词语沙拉」在开放假设下概率更低，
        // 约束到候选集反而会把概率自证式地推满。
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
        if let probability = hypotheses[NLLanguage(rawValue: language.code)] {
            score += probability * 2
        }
        if let confidence {
            score += confidence * 1.5
        }
        return score
    }

    /// 带滞回的胜者切换：挑战者必须明显优于现任才换，防止逐字闪烁。
    static func winnerIndex(
        current: Int?,
        scores: [Double],
        hysteresis: Double = 0.15
    ) -> Int? {
        guard let bestIndex = scores.indices.max(by: { scores[$0] < scores[$1] }),
              scores[bestIndex] > 0 else {
            return current
        }
        guard let current, current != bestIndex, scores.indices.contains(current) else {
            return bestIndex
        }
        return scores[bestIndex] > scores[current] + hysteresis ? bestIndex : current
    }
}

/// 识别引擎级联：iOS 26+ 且 SpeechTranscriber 真实可用（模拟器/老机型上
/// supportedLocales 为空）→ SpeechAnalyzer 路径，否则 SFSpeechRecognizer。
/// 可用性是运行时判定，#available 不够。
enum SpeechEngineFactory {
    @MainActor private static var cachedAnalyzerUsable: Bool?

    @MainActor
    static func makeService() async -> any VoiceTranscriptionService {
        if #available(iOS 26.0, *) {
            let usable: Bool
            if let cached = cachedAnalyzerUsable {
                usable = cached
            } else {
                usable = await SpeechAnalyzerTranscriptionService.isUsable()
                cachedAnalyzerUsable = usable
            }
            if usable {
                return SpeechAnalyzerTranscriptionService()
            }
        }
        return SFSpeechTranscriptionService()
    }
}

/// 实时管线调参。数值依据：volatile 稳定 + 静音双信号断句（生产系统 0.8–1.5s 区间）、
/// 350ms 部分重译节流（on-device MT 百 ms 级延迟）、SFSpeech 服务器识别 1 分钟上限。
enum VoiceTuning {
    static let partialTranslationThrottle: Duration = .milliseconds(350)
    static let endpointVolatileStability: TimeInterval = 0.9
    static let endpointSilenceRMSThreshold: Float = 0.015
    static let endpointSilenceDuration: TimeInterval = 0.55
    static let maxUtteranceDuration: TimeInterval = 55
    static let noSpeechAutoPause: TimeInterval = 60
    static let audioLevelInterval: TimeInterval = 1.0 / 15.0
    /// 开口后的自由改选窗口：此内胜者判定不带滞回，避免先出结果的轨道抢跑锁定。
    static let winnerFreeReelectionWindow: TimeInterval = 0.7
}

extension Language {
    /// ASR/TTS 用的 BCP-47 locale。
    var speechLocaleIdentifier: String {
        switch code {
        case "zh-Hans": "zh-CN"
        case "en": "en-US"
        case "ja": "ja-JP"
        case "ko": "ko-KR"
        case "fr": "fr-FR"
        case "es": "es-ES"
        case "de": "de-DE"
        default: code
        }
    }

    /// Translation 框架用的语言标识。
    var localeLanguage: Locale.Language {
        Locale.Language(identifier: code)
    }

    /// 语音页的语言不能是「自动检测」：auto 落到中文；对面已是中文则落到英文。
    func resolvedForVoice(counterpart: Language) -> Language {
        guard isAuto else { return self }
        return counterpart.code == Language.chinese.code ? .english : .chinese
    }
}
