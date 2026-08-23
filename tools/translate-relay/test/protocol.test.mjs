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

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  MAX_CODE_POINTS,
  MAX_SEGMENTS,
  RelayError,
  buildTranslatePayload,
  countCodePoints,
  mapUpstreamError,
  parseTranslateRequest,
  shapeTranslateResponse,
} from "../src/protocol.js";

function rejects(body, code) {
  assert.throws(
    () => parseTranslateRequest(body),
    (error) => error instanceof RelayError && error.code === code,
    `期望 code=${code}`
  );
}

test("码点数按 code point 算，不按 UTF-16 码元", () => {
  // "𠮷" 在 BMP 之外，String.length 是 2，码点只有 1。
  // 按 length 校验会在正好卡线的输入上误拒。
  assert.equal("𠮷".length, 2);
  assert.equal(countCodePoints(["𠮷"]), 1);
  assert.equal(countCodePoints(["ab", "中文"]), 4);
});

test("合法请求原样取出三个字段", () => {
  const parsed = parseTranslateRequest({ q: ["hello"], source: "en", target: "zh-CN" });
  assert.deepEqual(parsed, { q: ["hello"], source: "en", target: "zh-CN" });
});

test("source 省略或 null 都是自动检测", () => {
  assert.equal(parseTranslateRequest({ q: ["hi"], target: "zh-CN" }).source, null);
  assert.equal(parseTranslateRequest({ q: ["hi"], source: null, target: "zh-CN" }).source, null);
});

test("source 空串是笔误，不能静默当成自动检测", () => {
  rejects({ q: ["hi"], source: "", target: "zh-CN" }, "bad_request");
});

test("q 必须是非空字符串数组", () => {
  rejects({ q: [], target: "zh-CN" }, "bad_request");
  rejects({ q: "hi", target: "zh-CN" }, "bad_request");
  rejects({ q: ["hi", 42], target: "zh-CN" }, "bad_request");
  rejects({ target: "zh-CN" }, "bad_request");
});

test("target 缺失或空串直接拒", () => {
  rejects({ q: ["hi"] }, "bad_request");
  rejects({ q: ["hi"], target: "" }, "bad_request");
});

test("body 不是对象直接拒", () => {
  rejects(null, "bad_request");
  rejects([1, 2], "bad_request");
  rejects("hi", "bad_request");
});

test("超出 v3 的 30K 码点上限拦在中转，不发给谷歌", () => {
  rejects({ q: ["中".repeat(MAX_CODE_POINTS + 1)], target: "en" }, "payload_too_large");
  // 正好卡线要放行。
  const exact = parseTranslateRequest({ q: ["中".repeat(MAX_CODE_POINTS)], target: "en" });
  assert.equal(exact.q.length, 1);
});

test("条数上限单独判，报的错要能分辨是条数还是字数", () => {
  const many = Array.from({ length: MAX_SEGMENTS + 1 }, () => "hi");
  rejects({ q: many, target: "en" }, "too_many_segments");
});

test("payload 显式声明 text/plain——v3 默认 text/html 会回 &#39; 实体", () => {
  const payload = buildTranslatePayload({ q: ["it's"], source: "en", target: "zh-CN" });
  assert.equal(payload.mimeType, "text/plain");
  assert.deepEqual(payload.contents, ["it's"]);
  assert.equal(payload.targetLanguageCode, "zh-CN");
  assert.equal(payload.sourceLanguageCode, "en");
});

test("自动检测就是不传 sourceLanguageCode，v3 不认字面量 auto", () => {
  const payload = buildTranslatePayload({ q: ["hi"], source: null, target: "zh-CN" });
  assert.equal("sourceLanguageCode" in payload, false);
});

test("响应剥掉谷歌的结构，只留契约里那两个字段", () => {
  const shaped = shapeTranslateResponse(
    {
      translations: [
        { translatedText: "你好", detectedLanguageCode: "en", model: "nmt" },
        { translatedText: "世界" },
      ],
    },
    2
  );
  assert.deepEqual(shaped, {
    translations: [
      { text: "你好", detectedLanguage: "en" },
      { text: "世界", detectedLanguage: null },
    ],
  });
});

test("条数对不上算上游坏了，不能悄悄少还一条", () => {
  assert.throws(
    () => shapeTranslateResponse({ translations: [{ translatedText: "你好" }] }, 2),
    (error) => error instanceof RelayError && error.code === "upstream_malformed"
  );
  assert.throws(
    () => shapeTranslateResponse({}, 1),
    (error) => error instanceof RelayError && error.code === "upstream_malformed"
  );
});

test("上游 4xx 与 5xx 要分开——前者重试一万次也一样", () => {
  const rejected = mapUpstreamError(403, { error: { message: "API has not been used in project" } });
  assert.equal(rejected.code, "upstream_rejected");
  assert.equal(rejected.status, 403);
  assert.match(rejected.message, /API has not been used/);

  assert.equal(mapUpstreamError(429, {}).code, "rate_limited");
  assert.equal(mapUpstreamError(500, {}).code, "upstream_error");
  assert.equal(mapUpstreamError(503, {}).status, 502);
});

test("上游没给原因时也要有一句话，不能是 undefined", () => {
  assert.match(mapUpstreamError(400, null).message, /no reason/);
});
