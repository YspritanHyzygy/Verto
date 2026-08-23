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

// 签名这段是"部署了才发现坏"的高风险区：PEM 解析或 base64url 错一点，
// 换令牌就 400，而错误信息只会说 "Invalid JWT"。这里用真 RSA 密钥端到端验一遍。

import assert from "node:assert/strict";
import { generateKeyPairSync } from "node:crypto";
import { test } from "node:test";

import { signAssertion } from "../src/google.js";

const { publicKey, privateKey } = generateKeyPairSync("rsa", {
  modulusLength: 2048,
  publicKeyEncoding: { type: "spki", format: "der" },
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
});

function decodeSegment(segment) {
  const padded = segment.replace(/-/g, "+").replace(/_/g, "/");
  return JSON.parse(Buffer.from(padded, "base64").toString("utf8"));
}

async function verify(jwt) {
  const [header, claims, signature] = jwt.split(".");
  const key = await crypto.subtle.importKey(
    "spki",
    publicKey,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"]
  );
  return crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    key,
    Buffer.from(signature.replace(/-/g, "+").replace(/_/g, "/"), "base64"),
    new TextEncoder().encode(`${header}.${claims}`)
  );
}

test("签出来的 JWT 能被对应公钥验过", async () => {
  const jwt = await signAssertion(privateKey, "relay@p.iam.gserviceaccount.com", 1_700_000_000);
  assert.equal(jwt.split(".").length, 3);
  assert.equal(await verify(jwt), true);
});

test("私钥里的换行被转义成字面量 \\n 时也要能解——从 JSON 复制过来常是这样", () => {
  const escaped = privateKey.replace(/\n/g, "\\n");
  assert.equal(escaped.includes("\n"), false, "用例前提：这个变体里没有真换行");
  return signAssertion(escaped, "relay@p.iam.gserviceaccount.com", 1_700_000_000)
    .then((jwt) => verify(jwt))
    .then((ok) => assert.equal(ok, true));
});

test("claims 按谷歌 JWT bearer 流程的要求填", async () => {
  const now = 1_700_000_000;
  const jwt = await signAssertion(privateKey, "relay@p.iam.gserviceaccount.com", now);
  const [header, claims] = jwt.split(".");

  assert.deepEqual(decodeSegment(header), { alg: "RS256", typ: "JWT" });
  assert.deepEqual(decodeSegment(claims), {
    iss: "relay@p.iam.gserviceaccount.com",
    scope: "https://www.googleapis.com/auth/cloud-translation",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  });
});

test("base64url 不留 + / = 三个字符", async () => {
  // 这三个在 URL 和 JWT 里都是非法的，留着谷歌会直接判 Invalid JWT。
  const jwt = await signAssertion(privateKey, "relay@p.iam.gserviceaccount.com", 1_700_000_000);
  assert.equal(/[+/=]/.test(jwt), false);
});

test("私钥不是 PKCS#8 PEM 时报 misconfigured，而不是抛个看不懂的解码错", async () => {
  await assert.rejects(
    () => signAssertion("-----BEGIN PRIVATE KEY-----\n-----END PRIVATE KEY-----", "a@b", 1),
    (error) => error.code === "misconfigured"
  );
});
