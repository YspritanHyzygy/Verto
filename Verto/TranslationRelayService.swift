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

/// 自建中转（`tools/translate-relay`，部署在 Cloudflare Workers）。
///
/// **不叫 Google**：中转后面今天是 Cloud Translation v3 的 NMT，以后可能换成
/// Translation LLM 或别家，那是服务端一次改动，这一侧一行不动。契约里也没有任何
/// 谷歌特有的字段——App 不该知道背后是谁。
///
/// 服务账号私钥留在中转，不跟着包分发；客户端只带一个共享密钥头。
struct TranslationRelayService: TranslationService {
    var urlSession: URLSession = .shared
    let configuration: TranslationRelayConfiguration

    /// 中转的上限是 128 条 / 30K 码点。这里取更小的值留出余量：
    /// 一批太大时单次失败的代价（整批一起重试）和首块译文的等待都会变难看。
    static let maximumSegmentsPerBatch = 64
    static let maximumCodePointsPerBatch = 20_000
    /// 单条上限。超过它中转也会拒，不如在本地就给出「文本过长」。
    static let maximumTextLength = 5_000

    // MARK: - 单条

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        guard request.text.count <= Self.maximumTextLength else {
            throw TranslationError.textTooLong
        }
        let results = try await send(
            texts: [request.text],
            source: request.source,
            target: request.target
        )
        guard let first = results.first else { throw TranslationError.invalidResponse }
        return first
    }

    // MARK: - 批量

    func translateBatch(
        _ texts: [String],
        source: Language,
        target: Language
    ) -> AsyncStream<TranslationBatchElement> {
        AsyncStream { continuation in
            let task = Task {
                for chunk in Self.chunk(texts) {
                    if Task.isCancelled { break }
                    do {
                        let results = try await send(texts: chunk, source: source, target: target)
                        // 中转保证条数与顺序一一对应，对不上时它自己会报 upstream_malformed；
                        // 这里再挡一道，免得越界或错位地把 A 的译文填给 B。
                        guard results.count == chunk.count else {
                            yieldFailure(.invalidResponse, for: chunk, to: continuation)
                            continue
                        }
                        for (text, result) in zip(chunk, results) {
                            continuation.yield(TranslationBatchElement(text: text, result: .success(result)))
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        // 一批失败只影响这一批，后面的批照发。
                        yieldFailure(error as? TranslationError ?? .network, for: chunk, to: continuation)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func yieldFailure(
        _ error: TranslationError,
        for chunk: [String],
        to continuation: AsyncStream<TranslationBatchElement>.Continuation
    ) {
        for text in chunk {
            continuation.yield(TranslationBatchElement(text: text, result: .failure(error)))
        }
    }

    /// 按条数与码点数双重切分。码点数而不是 `count`：`String.count` 数的是
    /// 字素簇，中转和 v3 数的是码点，两者在 emoji 上差得远，用错会在边界上被拒。
    static func chunk(_ texts: [String]) -> [[String]] {
        var chunks: [[String]] = []
        var current: [String] = []
        var currentCodePoints = 0

        for text in texts {
            let codePoints = text.unicodeScalars.count
            let wouldExceed = current.count >= maximumSegmentsPerBatch
                || (!current.isEmpty && currentCodePoints + codePoints > maximumCodePointsPerBatch)
            if wouldExceed {
                chunks.append(current)
                current = []
                currentCodePoints = 0
            }
            current.append(text)
            currentCodePoints += codePoints
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    // MARK: - 传输

    private func send(texts: [String], source: Language, target: Language) async throws -> [TranslationResult] {
        let urlRequest = try Self.makeURLRequest(
            texts: texts,
            source: source,
            target: target,
            configuration: configuration
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TranslationError.network
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw Self.error(status: httpResponse.statusCode, body: data)
        }
        return try Self.parseResults(from: data)
    }

    static func makeURLRequest(
        texts: [String],
        source: Language,
        target: Language,
        configuration: TranslationRelayConfiguration
    ) throws -> URLRequest {
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // 令牌走请求头而不是 query：URL 会落进各级代理日志、崩溃报告与系统网络诊断，
        // 请求头不会。
        request.setValue(configuration.token, forHTTPHeaderField: "X-Verto-Token")
        request.httpBody = try JSONEncoder().encode(
            Payload(q: texts, source: relayCode(for: source), target: relayCode(for: target)!)
        )
        request.timeoutInterval = 20
        return request
    }

    private struct Payload: Encodable {
        let q: [String]
        /// nil 表示自动检测；契约里就是「省略或 null」。
        let source: String?
        let target: String
    }

    // MARK: - 解析

    private struct RelayResponse: Decodable {
        struct Item: Decodable {
            let text: String
            let detectedLanguage: String?
        }
        let translations: [Item]
    }

    private struct RelayErrorBody: Decodable {
        struct Detail: Decodable {
            let code: String
            let message: String
        }
        let error: Detail
    }

    static func parseResults(from data: Data) throws -> [TranslationResult] {
        let decoded: RelayResponse
        do {
            decoded = try JSONDecoder().decode(RelayResponse.self, from: data)
        } catch {
            throw TranslationError.invalidResponse
        }
        guard !decoded.translations.isEmpty else { throw TranslationError.invalidResponse }

        return decoded.translations.map { item in
            TranslationResult(
                text: item.text,
                detectedLanguage: item.detectedLanguage.flatMap(language(fromRelayCode:)),
                // v3 不返回备选译法。空数组会让文字页的「其他译法」入口自动隐藏。
                alternatives: []
            )
        }
    }

    /// 把中转的 HTTP 状态与结构化错误码翻成本地的错误类型。
    /// 分类的意义在于「值不值得重试」：4xx 是配置问题，重试一万次也一样。
    static func error(status: Int, body: Data) -> TranslationError {
        let detail = try? JSONDecoder().decode(RelayErrorBody.self, from: body)
        switch status {
        case 413:
            return .textTooLong
        case 429:
            return .rateLimited
        case 400..<500:
            return .rejected(
                code: detail?.error.code ?? "rejected",
                message: detail?.error.message ?? String(localized: "中转未返回错误详情")
            )
        default:
            return .serverError(status)
        }
    }

    // MARK: - 语言码

    /// 契约用的是谷歌那套语言码（中转直接透给 v3），所以简体中文要送 `zh-CN`。
    /// 自动检测送 nil。
    static func relayCode(for language: Language) -> String? {
        if language.isAuto { return nil }
        switch language.code {
        case "zh-Hans": return "zh-CN"
        default: return language.code
        }
    }

    static func language(fromRelayCode code: String) -> Language? {
        let normalized = code.lowercased()
        if normalized == "zh" || normalized.hasPrefix("zh-") { return .chinese }
        return Language.all.first { $0.code.lowercased() == normalized }
    }
}
