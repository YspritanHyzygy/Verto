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

/// 识别模型的字符表。随模型包一起下载，不进 app bundle——不同档位字表不同
/// （tiny 6904 条、small/medium 18708 条），焊进 bundle 就会和模型对不上。
struct OCRCharacterSet {
    /// 字表本体，索引 0 对应模型输出的第 1 类。
    let characters: [String]

    /// 模型输出的类别数 = 1（blank）+ 字表长度 + 1（空格）。
    /// 用它在加载时核对模型与字表是否配套，配不上就别硬跑——
    /// 差一位会让整篇译文变成乱码，且不报任何错。
    var expectedClassCount: Int { characters.count + 2 }

    /// 空格所在的类索引。PaddleOCR 的 `CTCLabelDecode` 在
    /// `use_space_char=True` 时把空格追加在字表**末尾之后**，
    /// 不在字表里（字表首项是 `!`，本身不含空格）。
    var spaceIndex: Int { characters.count + 1 }

    /// 从 charset.txt 解析：逐行一个字符。
    ///
    /// 不能用 `trimmingCharacters`——字表里有一条是**全角空格 U+3000**
    /// （small 档在第 1748 条），trim 会把它变成空串，从而让其后一万多个字符的
    /// 索引整体错位一位，识别结果会变成通篇乱码且不报任何错。只按换行切分。
    init(contentsOf url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        // 文件以换行结尾，切分后末尾会多出一个空串，只去掉这一个。
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { throw OCRCharacterSetError.empty }
        characters = lines
    }

    init(characters: [String]) {
        self.characters = characters
    }
}

enum OCRCharacterSetError: LocalizedError, Equatable {
    case empty
    /// 字表长度与模型输出类别数对不上。
    case classCountMismatch(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .empty, .classCountMismatch:
            String(localized: "识别模型文件损坏，请重新下载")
        }
    }
}

/// 贪心 CTC 解码。
///
/// 不做集束搜索：PaddleOCR 官方推理默认也是贪心，实测两者在印刷体上几乎没有差别，
/// 而集束搜索要在 18710 类上维护候选集，端侧划不来。
enum CTCDecoder {
    struct Result: Equatable {
        struct CharacterSpan: Equatable {
            var text: String
            var characterRange: Range<Int>
            var timeStepRange: Range<Int>
        }

        var text: String
        /// 被采纳的那些时间步上的概率均值。模型输出已过 softmax，直接取即可。
        var confidence: Float
        var characterSpans: [CharacterSpan]
        var timeSteps: Int

        init(
            text: String,
            confidence: Float,
            characterSpans: [CharacterSpan] = [],
            timeSteps: Int = 0
        ) {
            self.text = text
            self.confidence = confidence
            self.characterSpans = characterSpans
            self.timeSteps = timeSteps
        }
    }

    /// - Parameters:
    ///   - probabilities: 行优先的 `timeSteps × classCount`，每一行已过 softmax。
    ///   - timeSteps: 只解码前这么多步。补零区对应的尾部时间步要排除，
    ///     否则模型会在补白上吐出重复字符。
    static func decode(
        probabilities: [Float],
        timeSteps: Int,
        classCount: Int,
        characterSet: OCRCharacterSet
    ) -> Result {
        guard timeSteps > 0, classCount > 1,
              probabilities.count >= timeSteps * classCount else {
            return Result(text: "", confidence: 0)
        }
        return probabilities.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return Result(text: "", confidence: 0) }
            return decode(
                probabilities: base, stepStride: classCount,
                timeSteps: timeSteps, classCount: classCount, characterSet: characterSet
            )
        }
    }

    /// 直接在模型输出缓冲上解码，不要求先拷成密集数组。
    ///
    /// 存在的理由：识别输出是 `1 × 80 × 18710`，拷一份要 5.99MB，而这里只需要
    /// 逐时间步的 argmax。一张菜单三十行就是 180MB 的纯搬运。
    ///
    /// - Parameter stepStride: 相邻两个时间步之间的**元素**间隔。神经引擎会把
    ///   最内维补齐到 64 字节对齐（真机上 18710 → 18720），所以这个值通常
    ///   大于 `classCount`，不能拿 `classCount` 顶替。
    static func decode(
        probabilities: UnsafePointer<Float>,
        stepStride: Int,
        timeSteps: Int,
        classCount: Int,
        characterSet: OCRCharacterSet
    ) -> Result {
        guard timeSteps > 0, classCount > 1, stepStride >= classCount else {
            return Result(text: "", confidence: 0)
        }

        var text = ""
        var total: Float = 0
        var emitted = 0
        var previous = -1
        var spans: [Result.CharacterSpan] = []

        for step in 0..<timeSteps {
            let base = step * stepStride
            var best = 0
            var bestValue = probabilities[base]
            for k in 1..<classCount where probabilities[base + k] > bestValue {
                bestValue = probabilities[base + k]
                best = k
            }

            defer { previous = best }
            // 同一类别连续占用的时间步属于同一个字符；blank 把相同字符的两次
            // 出现隔开。范围只用于近似点击位置，不参与文本解码或质量判定。
            if best != 0, best == previous, let last = spans.indices.last {
                spans[last].timeStepRange = spans[last].timeStepRange.lowerBound..<(step + 1)
                continue
            }
            guard best != 0 else { continue }

            let symbol: String
            if best == characterSet.spaceIndex {
                symbol = " "
            } else {
                let index = best - 1
                guard index < characterSet.characters.count else { continue }
                symbol = characterSet.characters[index]
            }
            let start = text.count
            text += symbol
            spans.append(Result.CharacterSpan(
                text: symbol,
                characterRange: start..<(start + symbol.count),
                timeStepRange: step..<(step + 1)
            ))
            total += bestValue
            emitted += 1
        }

        return Result(
            text: text,
            confidence: emitted == 0 ? 0 : total / Float(emitted),
            characterSpans: spans,
            timeSteps: timeSteps
        )
    }
}
