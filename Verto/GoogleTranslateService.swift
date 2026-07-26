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

/// 谷歌翻译非官方免费接口（translate.googleapis.com, client=gtx）。
/// 无需 API Key；非官方接口无 SLA，限流与拦截页均映射为可重试错误。
struct GoogleTranslateService: TranslationService {
    var urlSession: URLSession = .shared

    static let endpoint = URL(string: "https://translate.googleapis.com/translate_a/single")!
    static let maximumTextLength = 5000

    func translate(_ request: TranslationRequest) async throws -> TranslationResult {
        guard request.text.count <= Self.maximumTextLength else {
            throw TranslationError.textTooLong
        }

        let urlRequest = Self.makeURLRequest(
            text: request.text,
            sourceCode: Self.googleCode(for: request.source),
            targetCode: Self.googleCode(for: request.target)
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
        switch httpResponse.statusCode {
        case 200:
            break
        case 429:
            throw TranslationError.rateLimited
        default:
            throw TranslationError.serverError(httpResponse.statusCode)
        }

        return try Self.parseResult(from: data)
    }

    // MARK: - Request building

    static func makeURLRequest(text: String, sourceCode: String, targetCode: String) -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "dt", value: "at"),
            URLQueryItem(name: "dj", value: "1"),
            URLQueryItem(name: "ie", value: "UTF-8"),
            URLQueryItem(name: "oe", value: "UTF-8"),
            URLQueryItem(name: "sl", value: sourceCode),
            URLQueryItem(name: "tl", value: targetCode)
        ]

        // 文本放进表单正文，避开 URL 长度上限。
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Data("q=\(formEncoded(text))".utf8)
        request.timeoutInterval = 15
        return request
    }

    /// 表单值编码：仅保留 RFC 3986 unreserved 字符，& / + / = / 换行等全部转义。
    static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    // MARK: - Response parsing

    struct Response: Decodable {
        struct Sentence: Decodable {
            let trans: String?
        }

        struct AlternativeGroup: Decodable {
            struct Alternative: Decodable {
                let wordPostproc: String

                enum CodingKeys: String, CodingKey {
                    case wordPostproc = "word_postproc"
                }
            }

            let alternative: [Alternative]?
        }

        let sentences: [Sentence]?
        let alternativeTranslations: [AlternativeGroup]?
        let src: String?

        enum CodingKeys: String, CodingKey {
            case sentences
            case alternativeTranslations = "alternative_translations"
            case src
        }
    }

    static func parseResult(from data: Data) throws -> TranslationResult {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TranslationError.invalidResponse
        }

        let text = (response.sentences ?? []).compactMap(\.trans).joined()
        guard !text.isEmpty else {
            throw TranslationError.invalidResponse
        }

        return TranslationResult(
            text: text,
            detectedLanguage: response.src.flatMap(language(fromGoogleCode:)),
            alternatives: alternatives(from: response, primary: text)
        )
    }

    /// 备选译法仅在整段输入只产生一组备选时可信；多句输入会得到逐段分组，
    /// 无法诚实拼回整段译文，直接不提供。
    private static func alternatives(from response: Response, primary: String) -> [String] {
        guard let groups = response.alternativeTranslations, groups.count == 1,
              let candidates = groups[0].alternative else {
            return []
        }

        var seen = Set<String>()
        return candidates
            .map(\.wordPostproc)
            .filter { candidate in
                !candidate.isEmpty && candidate != primary && seen.insert(candidate).inserted
            }
            .prefix(3)
            .map { $0 }
    }

    // MARK: - Language code mapping

    static func googleCode(for language: Language) -> String {
        switch language.code {
        case "zh-Hans": "zh-CN"
        default: language.code
        }
    }

    static func language(fromGoogleCode code: String) -> Language? {
        let normalized = code.lowercased()
        if normalized == "zh" || normalized.hasPrefix("zh-") {
            return .chinese
        }
        return Language.all.first { $0.code.lowercased() == normalized }
    }
}
