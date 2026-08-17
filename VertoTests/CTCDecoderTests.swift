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

/// 贪心 CTC 解码的判据。
///
/// 字表用三个字符，于是类别是：0=blank、1=A、2=B、3=C、4=空格。
/// 空格排在字表**之后**而不在字表里——这是 PaddleOCR `use_space_char=True` 的布局，
/// 摆错一位整篇译文会变乱码且不报错。
final class CTCDecoderTests: XCTestCase {

    private let characterSet = OCRCharacterSet(characters: ["A", "B", "C"])
    private var classCount: Int { characterSet.expectedClassCount }

    // MARK: - 折叠规则

    func testCollapsesRepeatsAndSkipsBlanks() {
        // A A blank B 空格 C → "AB C"
        let result = decode(steps: [1, 1, 0, 2, 4, 3])
        XCTAssertEqual(result.text, "AB C")
    }

    func testRepeatSeparatedByBlankEmitsTwice() {
        // A blank A → "AA"。blank 的作用就是把两个相同字符隔开，
        // 少了这一条，"aa" 这种叠字会被吞成一个。
        XCTAssertEqual(decode(steps: [1, 0, 1]).text, "AA")
    }

    func testAllBlankYieldsEmptyTextAndZeroConfidence() {
        let result = decode(steps: [0, 0, 0])
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.confidence, 0)
    }

    func testConfidenceAveragesOnlyTheEmittedSteps() {
        // 三步全被采纳，取值 0.9 / 0.5 / 0.7 → 0.7。
        // 被折叠掉的重复步和 blank 步不该进分母。
        var rows: [[Float]] = []
        rows.append(row(winner: 1, value: 0.9))
        rows.append(row(winner: 1, value: 0.1))   // 重复，折叠掉
        rows.append(row(winner: 0, value: 0.99))  // blank，跳过
        rows.append(row(winner: 2, value: 0.5))
        rows.append(row(winner: 3, value: 0.7))

        let result = CTCDecoder.decode(
            probabilities: rows.flatMap { $0 }, timeSteps: rows.count,
            classCount: classCount, characterSet: characterSet
        )
        XCTAssertEqual(result.text, "ABC")
        XCTAssertEqual(result.confidence, 0.7, accuracy: 0.0001)
    }

    func testClassBeyondTheCharacterSetIsDropped() {
        // 类别数比字表能解释的多时不该越界取字，只是丢掉这一步。
        let oversized = classCount + 3
        var values = [Float](repeating: 0, count: oversized * 2)
        values[0 * oversized + 1] = 1                 // A
        values[1 * oversized + (oversized - 1)] = 1   // 字表解释不了的类
        let result = CTCDecoder.decode(
            probabilities: values, timeSteps: 2,
            classCount: oversized, characterSet: characterSet
        )
        XCTAssertEqual(result.text, "A")
    }

    // MARK: - 守卫

    func testRejectsDegenerateShapes() {
        let values = [Float](repeating: 0.5, count: classCount * 4)
        XCTAssertEqual(
            CTCDecoder.decode(probabilities: values, timeSteps: 0,
                              classCount: classCount, characterSet: characterSet).text, "")
        XCTAssertEqual(
            CTCDecoder.decode(probabilities: values, timeSteps: 4,
                              classCount: 1, characterSet: characterSet).text, "")
        // 数据比声称的形状短——宁可空手而回也别读越界。
        XCTAssertEqual(
            CTCDecoder.decode(probabilities: values, timeSteps: 99,
                              classCount: classCount, characterSet: characterSet).text, "")
    }

    // MARK: - 带步长的零拷贝路径

    func testStridedDecodeSkipsThePaddingBetweenTimeSteps() {
        // 神经引擎把最内维补齐到 64 字节对齐，真机上 18710 类被补到 18720。
        // 这里用同样的形状关系：5 类、步长 8，补出来的 3 个格子填成最大值，
        // 一旦拿 classCount 当步长读，就会读进补齐区并选中错的类。
        let stepStride = classCount + 3
        let winners = [1, 0, 2, 4, 3]
        var values = [Float](repeating: 0, count: winners.count * stepStride)
        for (step, winner) in winners.enumerated() {
            let base = step * stepStride
            values[base + winner] = 0.8
            for padding in classCount..<stepStride { values[base + padding] = 1 }
        }

        let result = values.withUnsafeBufferPointer { buffer in
            CTCDecoder.decode(
                probabilities: buffer.baseAddress!, stepStride: stepStride,
                timeSteps: winners.count, classCount: classCount,
                characterSet: characterSet
            )
        }

        XCTAssertEqual(result.text, "AB C", "补齐区被当成有效类读进来了")
        XCTAssertEqual(result.confidence, 0.8, accuracy: 0.0001)
    }

    func testStridedDecodeMatchesTheDenseOverload() {
        // 步长恰好等于类别数时，两个入口必须给出同一个结果——
        // 数组版就是靠委托给指针版来保证只有一份折叠逻辑的。
        let winners = [2, 2, 0, 1, 4, 3, 3]
        let dense = winners.flatMap { row(winner: $0, value: 0.75) }

        let viaArray = CTCDecoder.decode(
            probabilities: dense, timeSteps: winners.count,
            classCount: classCount, characterSet: characterSet
        )
        let viaPointer = dense.withUnsafeBufferPointer { buffer in
            CTCDecoder.decode(
                probabilities: buffer.baseAddress!, stepStride: classCount,
                timeSteps: winners.count, classCount: classCount,
                characterSet: characterSet
            )
        }
        XCTAssertEqual(viaArray, viaPointer)
    }

    func testStridedDecodeRejectsAStrideNarrowerThanTheClassCount() {
        let values = [Float](repeating: 0.5, count: classCount * 4)
        let result = values.withUnsafeBufferPointer { buffer in
            CTCDecoder.decode(
                probabilities: buffer.baseAddress!, stepStride: classCount - 1,
                timeSteps: 4, classCount: classCount, characterSet: characterSet
            )
        }
        XCTAssertEqual(result.text, "", "步长小于类别数是不可能的布局，应该直接拒绝")
    }

    // MARK: - 工具

    private func row(winner: Int, value: Float) -> [Float] {
        var values = [Float](repeating: 0, count: classCount)
        values[winner] = value
        return values
    }

    private func decode(steps: [Int]) -> CTCDecoder.Result {
        CTCDecoder.decode(
            probabilities: steps.flatMap { row(winner: $0, value: 0.9) },
            timeSteps: steps.count, classCount: classCount, characterSet: characterSet
        )
    }
}
