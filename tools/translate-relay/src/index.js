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

// 译境（Verto）翻译中转。
//
// App 只认识这一个接口，不认识谷歌。中转后面挂 NMT、挂 Translation LLM、
// 还是挂别家，都是这里一次改动，客户端一行不动。

import { verifyCaller, CALLER_TOKEN_HEADER } from "./auth.js";
import { translateText } from "./google.js";
import { RelayError, parseTranslateRequest } from "./protocol.js";

export default {
  async fetch(request, env) {
    try {
      return json(200, await handle(request, env));
    } catch (error) {
      if (error instanceof RelayError) {
        return json(error.status, error.toResponseBody());
      }
      // 意外错误不回显细节——堆栈里可能夹着令牌或私钥片段。
      console.error("relay failed", error);
      return json(500, { error: { code: "internal", message: "relay failed" } });
    }
  },
};

async function handle(request, env) {
  const url = new URL(request.url);

  if (url.pathname === "/health" && request.method === "GET") {
    return { ok: true };
  }
  if (url.pathname !== "/v1/translate") {
    throw new RelayError(404, "not_found", `no route for ${url.pathname}`);
  }
  if (request.method !== "POST") {
    throw new RelayError(405, "method_not_allowed", "use POST");
  }

  await verifyCaller(request, env);
  await enforceRateLimit(request, env);

  let body;
  try {
    body = await request.json();
  } catch {
    throw new RelayError(400, "bad_request", "body is not valid JSON");
  }

  return await translateText(env, parseTranslateRequest(body));
}

/// 令牌泄漏后的第一道减速带。按调用方 IP 计，因为令牌只有一个、
/// 按它计等于全体用户共用一个桶。
///
/// binding 没配时直接放行而不是拒绝：限流是纵深防御，不该成为单点故障；
/// 真正的账单硬顶在 GCP 的配额上限那里。
async function enforceRateLimit(request, env) {
  if (!env.RELAY_RATE_LIMITER) return;
  const key = request.headers.get("CF-Connecting-IP") ?? "unknown";
  const { success } = await env.RELAY_RATE_LIMITER.limit({ key });
  if (!success) {
    throw new RelayError(429, "rate_limited", "too many requests from this address");
  }
}

function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      // 浏览器不是这个接口的调用方，明确不开放跨域。
      "Cache-Control": "no-store",
      Vary: CALLER_TOKEN_HEADER,
    },
  });
}
