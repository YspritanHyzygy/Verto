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

// 路由、鉴权、限流、契约校验这几条路径都在够到谷歌之前就结束了，
// 所以可以直接在 Node 里调 fetch handler，不必起 workerd。
// 签名换令牌与真正调 v3 只能靠 `wrangler dev` 真跑。

import assert from "node:assert/strict";
import { test } from "node:test";

import worker from "../src/index.js";
import { MAX_CODE_POINTS } from "../src/protocol.js";

const TOKEN = "test-token";
const ENV = { VERTO_SHARED_TOKEN: TOKEN, GCP_PROJECT_ID: "p", GOOGLE_SA_EMAIL: "a@b", GOOGLE_SA_PRIVATE_KEY: "x" };

async function call({ path = "/v1/translate", method = "POST", token = TOKEN, body, env = ENV } = {}) {
  const headers = { "Content-Type": "application/json" };
  if (token !== null) headers["X-Verto-Token"] = token;
  const request = new Request(`https://relay.test${path}`, {
    method,
    headers,
    body: method === "GET" ? undefined : JSON.stringify(body ?? { q: ["hi"], target: "zh-CN" }),
  });
  const response = await worker.fetch(request, env);
  return { status: response.status, json: await response.json() };
}

test("健康检查不需要令牌", async () => {
  const { status, json } = await call({ path: "/health", method: "GET", token: null });
  assert.equal(status, 200);
  assert.deepEqual(json, { ok: true });
});

test("没带令牌就是 401，且在读 body 之前就拒", async () => {
  const { status, json } = await call({ token: null });
  assert.equal(status, 401);
  assert.equal(json.error.code, "unauthorized");
});

test("令牌不对也是 401", async () => {
  const { status, json } = await call({ token: "wrong" });
  assert.equal(status, 401);
  assert.equal(json.error.code, "unauthorized");
});

test("中转自己没配令牌时要报错，不能变成谁都能调", async () => {
  const { status, json } = await call({ env: { ...ENV, VERTO_SHARED_TOKEN: "" } });
  assert.equal(status, 500);
  assert.equal(json.error.code, "misconfigured");
});

test("路径和方法不对分别是 404 / 405", async () => {
  assert.equal((await call({ path: "/v2/translate" })).status, 404);
  assert.equal((await call({ method: "GET" })).status, 405);
});

test("body 不是 JSON 时报 bad_request 而不是 500", async () => {
  const request = new Request("https://relay.test/v1/translate", {
    method: "POST",
    headers: { "X-Verto-Token": TOKEN, "Content-Type": "application/json" },
    body: "{ not json",
  });
  const response = await worker.fetch(request, ENV);
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error.code, "bad_request");
});

test("超限的请求在中转就被拦下，不会打到谷歌", async () => {
  const { status, json } = await call({ body: { q: ["中".repeat(MAX_CODE_POINTS + 1)], target: "en" } });
  assert.equal(status, 413);
  assert.equal(json.error.code, "payload_too_large");
});

test("限流 binding 说不行就回 429", async () => {
  const env = { ...ENV, RELAY_RATE_LIMITER: { limit: async () => ({ success: false }) } };
  const { status, json } = await call({ env });
  assert.equal(status, 429);
  assert.equal(json.error.code, "rate_limited");
});

test("没配限流 binding 时放行——限流是纵深防御，不该成为单点故障", async () => {
  // 放行后会继续往下走到谷歌那步；这里只要确认它不是 429 就够了。
  const { status } = await call({ env: { ...ENV, RELAY_RATE_LIMITER: undefined } });
  assert.notEqual(status, 429);
});

test("意外错误不回显细节——堆栈里可能夹着令牌或私钥片段", async () => {
  const env = {
    ...ENV,
    RELAY_RATE_LIMITER: {
      limit: async () => {
        throw new Error("boom: super-secret-token-value");
      },
    },
  };
  const { status, json } = await call({ env });
  assert.equal(status, 500);
  assert.equal(json.error.code, "internal");
  assert.equal(JSON.stringify(json).includes("super-secret"), false);
});
