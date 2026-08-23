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

// 对外契约与限额校验。这一层是纯函数，不碰网络也不碰 env，
// 所以可以直接用 `node --test` 跑，不必起 workerd。
//
// 契约刻意不暴露谷歌：请求体里没有任何 v3 特有的字段名，响应也不透传谷歌的结构。
// 后面换成 Translation LLM 或别家引擎时，改的是 google.js，客户端一行不动。

/// Cloud Translation v3 单请求上限就是 30K code points（不是 UTF-16 长度，也不是字节）。
/// 客户端也分批，这里是第二道闸——两边都拦，哪边漏了另一边还在。
export const MAX_CODE_POINTS = 30_000;

/// 单请求条数上限。v3 没有明文规定条数，但一次塞几百条会让单个失败的代价过大
/// （整批一起重试），也会拖长首块译文出现的时间。
export const MAX_SEGMENTS = 128;

export class RelayError extends Error {
  constructor(status, code, message) {
    super(message);
    this.name = "RelayError";
    this.status = status;
    this.code = code;
  }

  toResponseBody() {
    return { error: { code: this.code, message: this.message } };
  }
}

/// 码点数，不是 `String.length`。JS 的 length 数的是 UTF-16 码元，
/// emoji 和增补平面汉字各算两个，用它校验会在正好卡线时误拒。
export function countCodePoints(strings) {
  let total = 0;
  for (const value of strings) total += [...value].length;
  return total;
}

export function parseTranslateRequest(body) {
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    throw new RelayError(400, "bad_request", "body must be a JSON object");
  }

  const { q, source, target } = body;

  if (!Array.isArray(q) || q.length === 0) {
    throw new RelayError(400, "bad_request", "q must be a non-empty array of strings");
  }
  if (!q.every((item) => typeof item === "string")) {
    throw new RelayError(400, "bad_request", "q must contain only strings");
  }
  if (q.length > MAX_SEGMENTS) {
    throw new RelayError(413, "too_many_segments", `q holds ${q.length} segments, max is ${MAX_SEGMENTS}`);
  }

  const codePoints = countCodePoints(q);
  if (codePoints > MAX_CODE_POINTS) {
    throw new RelayError(413, "payload_too_large", `q holds ${codePoints} code points, max is ${MAX_CODE_POINTS}`);
  }

  if (typeof target !== "string" || target.length === 0) {
    throw new RelayError(400, "bad_request", "target must be a non-empty language code");
  }
  // source 省略或 null 表示自动检测。空串是笔误而不是"自动"，明确拒掉，
  // 否则客户端一个手滑就静默变成了检测模式。
  if (source !== undefined && source !== null && (typeof source !== "string" || source.length === 0)) {
    throw new RelayError(400, "bad_request", "source must be a non-empty language code, or null for auto-detect");
  }

  return { q, source: source ?? null, target };
}

export function buildTranslatePayload({ q, source, target }) {
  const payload = {
    contents: q,
    targetLanguageCode: target,
    // v3 的 mimeType 默认是 text/html，会把 ' 之类的字符转成 &#39; 实体回来。
    // 我们送的是 OCR 出来的纯文本，必须显式声明。
    mimeType: "text/plain",
  };
  // 自动检测就是"不传 sourceLanguageCode"。v3 不认字面量 "auto"。
  if (source !== null) payload.sourceLanguageCode = source;
  return payload;
}

export function shapeTranslateResponse(googleJson, expectedCount) {
  const translations = googleJson?.translations;
  if (!Array.isArray(translations) || translations.length !== expectedCount) {
    throw new RelayError(
      502,
      "upstream_malformed",
      `expected ${expectedCount} translations, upstream returned ${translations?.length ?? "none"}`
    );
  }
  return {
    translations: translations.map((item) => ({
      text: typeof item?.translatedText === "string" ? item.translatedText : "",
      detectedLanguage: item?.detectedLanguageCode ?? null,
    })),
  };
}

/// 谷歌的错误分成两类，客户端要区别对待：4xx 是配置问题（API 没启用、
/// 计费没开、服务账号缺角色），重试一万次也一样；5xx 才值得重试。
export function mapUpstreamError(status, googleJson) {
  const message = googleJson?.error?.message ?? "upstream gave no reason";
  if (status === 429) return new RelayError(429, "rate_limited", message);
  if (status >= 400 && status < 500) return new RelayError(status, "upstream_rejected", message);
  return new RelayError(502, "upstream_error", message);
}
