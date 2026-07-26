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

final class GoogleTranslateServiceTests: XCTestCase {

    // MARK: - Response parsing

    func testParsesSingleSentenceWithAlternatives() throws {
        let json = """
        {
          "sentences": [{"trans": "Hello", "orig": "你好", "backend": 10}],
          "alternative_translations": [{
            "src_phrase": "你好",
            "alternative": [
              {"word_postproc": "Hello", "score": 1000, "has_preceding_space": true, "attach_to_next_token": false},
              {"word_postproc": "Hi", "score": 1000, "has_preceding_space": true, "attach_to_next_token": false},
              {"word_postproc": "Hello there", "score": 0, "has_preceding_space": true, "attach_to_next_token": false},
              {"word_postproc": "Hi", "score": 0, "has_preceding_space": true, "attach_to_next_token": false}
            ],
            "srcunicodeoffsets": [{"begin": 0, "end": 2}],
            "raw_src_segment": "你好",
            "start_pos": 0,
            "end_pos": 0
          }],
          "src": "zh-CN",
          "confidence": 1.0,
          "ld_result": {"srclangs": ["zh-CN"], "srclangs_confidences": [1.0], "extended_srclangs": ["zh-CN"]}
        }
        """
        let result = try GoogleTranslateService.parseResult(from: Data(json.utf8))

        XCTAssertEqual(result.text, "Hello")
        // 与主译文相同的候选被剔除，重复项去重。
        XCTAssertEqual(result.alternatives, ["Hi", "Hello there"])
        XCTAssertEqual(result.detectedLanguage, .chinese)
    }

    func testJoinsMultipleSentencesAndDropsPerSegmentAlternatives() throws {
        let json = """
        {
          "sentences": [
            {"trans": "Hello. ", "orig": "你好。"},
            {"trans": "Goodbye.", "orig": "再见。"}
          ],
          "alternative_translations": [
            {"alternative": [{"word_postproc": "Hi."}], "raw_src_segment": "你好。"},
            {"alternative": [{"word_postproc": "Bye."}], "raw_src_segment": "再见。"}
          ],
          "src": "zh-CN"
        }
        """
        let result = try GoogleTranslateService.parseResult(from: Data(json.utf8))

        XCTAssertEqual(result.text, "Hello. Goodbye.")
        XCTAssertEqual(result.alternatives, [])
    }

    func testSkipsSentenceEntriesWithoutTrans() throws {
        let json = """
        {
          "sentences": [
            {"trans": "Hi", "orig": "嗨"},
            {"src_translit": "hāi"}
          ],
          "src": "zh-CN"
        }
        """
        let result = try GoogleTranslateService.parseResult(from: Data(json.utf8))

        XCTAssertEqual(result.text, "Hi")
    }

    func testUnknownDetectedLanguageMapsToNil() throws {
        let json = """
        {"sentences": [{"trans": "Привет"}], "src": "ru"}
        """
        let result = try GoogleTranslateService.parseResult(from: Data(json.utf8))

        XCTAssertNil(result.detectedLanguage)
    }

    func testGarbageDataThrowsInvalidResponse() {
        let html = Data("<html><body>Sorry...</body></html>".utf8)

        XCTAssertThrowsError(try GoogleTranslateService.parseResult(from: html)) { error in
            XCTAssertEqual(error as? TranslationError, .invalidResponse)
        }
    }

    func testEmptySentencesThrowsInvalidResponse() {
        let json = Data("{\"src\": \"en\"}".utf8)

        XCTAssertThrowsError(try GoogleTranslateService.parseResult(from: json)) { error in
            XCTAssertEqual(error as? TranslationError, .invalidResponse)
        }
    }

    // MARK: - Request building

    func testRequestConstruction() throws {
        let request = GoogleTranslateService.makeURLRequest(
            text: "a&b +c\nd",
            sourceCode: "auto",
            targetCode: "zh-CN"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/x-www-form-urlencoded; charset=utf-8"
        )

        let components = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
        )
        XCTAssertEqual(components.host, "translate.googleapis.com")
        XCTAssertEqual(components.path, "/translate_a/single")

        let items = try XCTUnwrap(components.queryItems)
        func values(_ name: String) -> [String?] {
            items.filter { $0.name == name }.map(\.value)
        }
        XCTAssertEqual(values("client"), ["gtx"])
        XCTAssertEqual(values("dt"), ["t", "at"])
        XCTAssertEqual(values("dj"), ["1"])
        XCTAssertEqual(values("sl"), ["auto"])
        XCTAssertEqual(values("tl"), ["zh-CN"])

        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertEqual(body, "q=a%26b%20%2Bc%0Ad")
    }

    // MARK: - Language code mapping

    func testGoogleCodeMapping() {
        XCTAssertEqual(GoogleTranslateService.googleCode(for: .chinese), "zh-CN")
        XCTAssertEqual(GoogleTranslateService.googleCode(for: .auto), "auto")
        XCTAssertEqual(GoogleTranslateService.googleCode(for: .english), "en")
        XCTAssertEqual(GoogleTranslateService.googleCode(for: .japanese), "ja")
    }

    func testLanguageFromGoogleCode() {
        XCTAssertEqual(GoogleTranslateService.language(fromGoogleCode: "zh-CN"), .chinese)
        XCTAssertEqual(GoogleTranslateService.language(fromGoogleCode: "zh-TW"), .chinese)
        XCTAssertEqual(GoogleTranslateService.language(fromGoogleCode: "zh"), .chinese)
        XCTAssertEqual(GoogleTranslateService.language(fromGoogleCode: "en"), .english)
        XCTAssertEqual(GoogleTranslateService.language(fromGoogleCode: "EN"), .english)
        XCTAssertEqual(GoogleTranslateService.language(fromGoogleCode: "ja"), .japanese)
        XCTAssertNil(GoogleTranslateService.language(fromGoogleCode: "ru"))
    }
}
