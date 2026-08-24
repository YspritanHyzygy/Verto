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

import XCTest
@testable import Verto

/// 中转客户端：请求构造、响应解析、错误分类、分批。
/// 这几处错了都不会崩，只会安静地翻错或整页红叹号，所以钉死在这里。
final class TranslationRelayServiceTests: XCTestCase {
    private let configuration = TranslationRelayConfiguration(
        host: "api.example.com",
        token: "secret-token"
    )!

    // MARK: - 配置

    func testConfigurationBuildsHTTPSEndpointFromHostAlone() {
        // 只存主机名是因为 xcconfig 把 // 当注释起点，写完整 URL 会被截成 "https:"。
        XCTAssertEqual(configuration.endpoint.absoluteString, "https://api.example.com/v1/translate")
    }

    func testConfigurationIsNilWhenEitherHalfIsMissing() {
        XCTAssertNil(TranslationRelayConfiguration(host: nil, token: "t"))
        XCTAssertNil(TranslationRelayConfiguration(host: "api.example.com", token: nil))
        XCTAssertNil(TranslationRelayConfiguration(host: "", token: "t"))
        XCTAssertNil(TranslationRelayConfiguration(host: "api.example.com", token: "   "))
    }

    func testConfigurationTrimsWhitespaceFromXcconfigValues() {
        let padded = TranslationRelayConfiguration(host: "  api.example.com  ", token: "  t  ")
        XCTAssertEqual(padded?.endpoint.absoluteString, "https://api.example.com/v1/translate")
        XCTAssertEqual(padded?.token, "t")
    }

    // MARK: - 请求构造

    private struct SentPayload: Decodable {
        let q: [String]
        let source: String?
        let target: String
    }

    private func payload(of request: URLRequest) throws -> SentPayload {
        try JSONDecoder().decode(SentPayload.self, from: XCTUnwrap(request.httpBody))
    }

    func testRequestCarriesTokenInHeaderNotQuery() throws {
        let request = try TranslationRelayService.makeURLRequest(
            texts: ["hi"], source: .english, target: .chinese, configuration: configuration
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Verto-Token"), "secret-token")
        // URL 会落进各级代理日志、崩溃报告与系统网络诊断，请求头不会。
        XCTAssertFalse(request.url?.absoluteString.contains("secret-token") ?? true)
    }

    func testRequestSendsEveryTextInOneBatch() throws {
        let request = try TranslationRelayService.makeURLRequest(
            texts: ["a", "b", "c"], source: .english, target: .chinese, configuration: configuration
        )

        XCTAssertEqual(try payload(of: request).q, ["a", "b", "c"])
    }

    func testAutoSourceIsSentAsNullNotTheLiteralAuto() throws {
        // v3 不认字面量 "auto"，自动检测就是不传 source。
        let request = try TranslationRelayService.makeURLRequest(
            texts: ["hi"], source: .auto, target: .chinese, configuration: configuration
        )

        XCTAssertNil(try payload(of: request).source)
        XCTAssertEqual(try payload(of: request).target, "zh-CN")
    }

    // MARK: - 语言码

    func testSimplifiedChineseGoesOutAsGoogleStyleCode() {
        XCTAssertEqual(TranslationRelayService.relayCode(for: .chinese), "zh-CN")
        XCTAssertEqual(TranslationRelayService.relayCode(for: .english), "en")
        XCTAssertEqual(TranslationRelayService.relayCode(for: .japanese), "ja")
        XCTAssertNil(TranslationRelayService.relayCode(for: .auto))
    }

    func testAnyChineseVariantMapsBackToSimplified() {
        XCTAssertEqual(TranslationRelayService.language(fromRelayCode: "zh-CN"), .chinese)
        XCTAssertEqual(TranslationRelayService.language(fromRelayCode: "zh-TW"), .chinese)
        XCTAssertEqual(TranslationRelayService.language(fromRelayCode: "zh"), .chinese)
        XCTAssertEqual(TranslationRelayService.language(fromRelayCode: "EN"), .english)
        XCTAssertNil(TranslationRelayService.language(fromRelayCode: "ru"))
    }

    // MARK: - 响应解析

    func testParsesTranslationsInOrderWithDetectedLanguage() throws {
        let json = """
        {"translations":[
          {"text":"你好","detectedLanguage":"en"},
          {"text":"早上好","detectedLanguage":null}
        ]}
        """
        let results = try TranslationRelayService.parseResults(from: Data(json.utf8))

        XCTAssertEqual(results.map(\.text), ["你好", "早上好"])
        XCTAssertEqual(results[0].detectedLanguage, .english)
        XCTAssertNil(results[1].detectedLanguage)
    }

    func testAlternativesAreAlwaysEmptyBecauseV3HasNone() throws {
        // 免费接口会回备选译法，v3 不会。空数组让文字页的「其他译法」入口自动隐藏。
        let json = #"{"translations":[{"text":"你好","detectedLanguage":"en"}]}"#
        XCTAssertEqual(try TranslationRelayService.parseResults(from: Data(json.utf8)).first?.alternatives, [])
    }

    func testGarbageAndEmptyBodiesBothBecomeInvalidResponse() {
        for body in ["<html>nope</html>", #"{"translations":[]}"#, "{}"] {
            XCTAssertThrowsError(try TranslationRelayService.parseResults(from: Data(body.utf8))) { error in
                XCTAssertEqual(error as? TranslationError, .invalidResponse, "body: \(body)")
            }
        }
    }

    // MARK: - 错误分类

    private func errorBody(code: String, message: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8)
    }

    func testConfigurationProblemsSurfaceAsRejectedWithGooglesOwnReason() {
        // 4xx 是配置问题——API 没启用、计费没开、服务账号缺角色。重试一万次也一样，
        // 所以原因必须能传到用户眼前，而不是又一个没有信息的红叹号。
        let error = TranslationRelayService.error(
            status: 403,
            body: errorBody(code: "upstream_rejected", message: "API has not been used in project")
        )

        XCTAssertEqual(
            error,
            .rejected(code: "upstream_rejected", message: "API has not been used in project")
        )
    }

    func testUnauthorizedGetsItsOwnSentenceInsteadOfTheRelaysEnglish() {
        let error = TranslationRelayService.error(
            status: 401,
            body: errorBody(code: "unauthorized", message: "caller token missing or wrong")
        )

        XCTAssertEqual(error, .rejected(code: "unauthorized", message: "caller token missing or wrong"))
        // 令牌不对是配置问题，摆英文原文给用户没有意义。
        XCTAssertEqual(
            error.errorDescription,
            String(localized: "这份构建的翻译服务令牌无效，请检查中转配置")
        )
    }

    func testTranslationEngineLabelReflectsEffectiveService() {
        XCTAssertEqual(
            TranslationEngine.google.displayName(relayConfigured: true),
            String(localized: "谷歌翻译")
        )
        XCTAssertEqual(
            TranslationEngine.google.subtitle(relayConfigured: true),
            String(localized: "在线翻译")
        )
        XCTAssertEqual(
            TranslationEngine.google.displayName(relayConfigured: false),
            String(localized: "系统翻译")
        )
        XCTAssertEqual(
            TranslationEngine.google.subtitle(relayConfigured: false),
            String(localized: "设备端离线翻译")
        )
    }

    func testRetryableAndNonRetryableStatusesAreKeptApart() {
        XCTAssertEqual(TranslationRelayService.error(status: 413, body: Data()), .textTooLong)
        XCTAssertEqual(TranslationRelayService.error(status: 429, body: Data()), .rateLimited)
        XCTAssertEqual(TranslationRelayService.error(status: 500, body: Data()), .serverError(500))
        XCTAssertEqual(TranslationRelayService.error(status: 502, body: Data()), .serverError(502))
    }

    func testRejectionWithoutABodyStillCarriesAReadableReason() {
        guard case .rejected(_, let message) = TranslationRelayService.error(status: 400, body: Data()) else {
            return XCTFail("400 应当归为 rejected")
        }
        XCTAssertFalse(message.isEmpty)
    }

    // MARK: - 分批

    func testChunkSplitsBySegmentCount() {
        let texts = (0..<(TranslationRelayService.maximumSegmentsPerBatch * 2 + 1)).map(String.init)
        let chunks = TranslationRelayService.chunk(texts)

        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.flatMap { $0 }, texts, "分批不得丢条目或改顺序")
        XCTAssertNil(chunks.first { $0.count > TranslationRelayService.maximumSegmentsPerBatch })
    }

    func testChunkSplitsByCodePointBudget() {
        let long = String(repeating: "中", count: TranslationRelayService.maximumCodePointsPerBatch / 2 + 1)
        let chunks = TranslationRelayService.chunk([long, long, long])

        XCTAssertEqual(chunks.count, 3, "每条都超过半个预算，只能各成一批")
        XCTAssertEqual(chunks.flatMap { $0 }.count, 3)
    }

    func testSingleOversizedTextStillGetsItsOwnChunkRatherThanBeingDropped() {
        // 一条就超预算时不能丢——让它自己成一批发出去，由中转给出明确的 413，
        // 而不是在客户端悄悄消失。
        let huge = String(repeating: "字", count: TranslationRelayService.maximumCodePointsPerBatch * 2)
        XCTAssertEqual(TranslationRelayService.chunk([huge]), [[huge]])
    }

    func testChunkOfNothingIsNothing() {
        XCTAssertTrue(TranslationRelayService.chunk([]).isEmpty)
    }

    // MARK: - 引擎解析

    func testConfiguredBuildAlwaysUsesTheRelay() {
        let service = TranslationEngine.google.makeService(relay: configuration)
        XCTAssertTrue(service is TranslationRelayService)
    }

    func testBuildWithoutARelayFallsBackToSystemTranslation() {
        // 开源构建：没有中转地址，落到系统离线翻译，让克隆仓库的人零配置能跑起来。
        let service = TranslationEngine.google.makeService(relay: nil)
        XCTAssertTrue(service is AppleBackedTranslationService)
    }

    func testEveryEngineResolvesToTheRelayWhenOneIsConfigured() {
        // custom / llm 在 UI 里不可选，但防御性解析不能把用户丢进系统翻译——
        // 配了中转就走中转，没有例外。
        for engine in TranslationEngine.allCases {
            XCTAssertTrue(
                engine.makeService(relay: configuration) is TranslationRelayService,
                "\(engine.rawValue) 解析错了"
            )
        }
    }

    // MARK: - 批量默认实现

    func testDefaultBatchFansOutAndReportsEveryText() async {
        // 没有原生批量能力的实现走协议默认实现：并发发单条，谁先回来吐谁。
        let texts = ["你好", "Good morning", "谢谢你的款待。"]
        var seen: [String: String] = [:]

        for await element in CannedTranslationService().translateBatch(
            texts, source: .chinese, target: .english
        ) {
            if case .success(let result) = element.result { seen[element.text] = result.text }
        }

        XCTAssertEqual(Set(seen.keys), Set(texts), "每条都要有交代，少一条块就永远转圈")
    }

    func testDefaultBatchOfNothingFinishesImmediately() async {
        var count = 0
        for await _ in CannedTranslationService().translateBatch([], source: .chinese, target: .english) {
            count += 1
        }
        XCTAssertEqual(count, 0)
    }
}
