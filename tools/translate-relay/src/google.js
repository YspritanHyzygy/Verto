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

// Cloud Translation v3 的调用与鉴权。
//
// v3 只认 OAuth，不认 API Key（官方 translateText 的 Authorization Scopes 一栏
// 只列了两个 OAuth scope）。所以这里自己走服务账号的 JWT bearer 流程：
// 用私钥签一个 JWT，拿它到 oauth2 换 access token，再用 token 调 v3。

import { RelayError, buildTranslatePayload, mapUpstreamError, shapeTranslateResponse } from "./protocol.js";

const TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token";
const SCOPE = "https://www.googleapis.com/auth/cloud-translation";
/// 提前这么多秒就认为过期，免得请求在飞行途中恰好跨过失效时刻。
const EXPIRY_SAFETY_MARGIN_SECONDS = 120;

/// 模块作用域的 token 缓存。同一个 isolate 内复用，跨 isolate 各签各的——
/// 签一次约 1–2ms、一小时一次，重复签的代价可以忽略，不值得为它引入 KV。
let cachedToken = null;

export async function translateText(env, parsed) {
  const token = await accessToken(env);
  const project = requireEnv(env, "GCP_PROJECT_ID");

  const response = await fetch(
    `https://translation.googleapis.com/v3/projects/${encodeURIComponent(project)}/locations/global:translateText`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json; charset=utf-8",
      },
      body: JSON.stringify(buildTranslatePayload(parsed)),
    }
  );

  const json = await response.json().catch(() => null);
  if (!response.ok) {
    // token 可能被提前吊销；丢掉缓存，下一次请求会重新换。
    if (response.status === 401) cachedToken = null;
    throw mapUpstreamError(response.status, json);
  }
  return shapeTranslateResponse(json, parsed.q.length);
}

async function accessToken(env) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.expiresAt - EXPIRY_SAFETY_MARGIN_SECONDS > now) {
    return cachedToken.value;
  }

  const email = requireEnv(env, "GOOGLE_SA_EMAIL");
  const assertion = await signAssertion(requireEnv(env, "GOOGLE_SA_PRIVATE_KEY"), email, now);

  const response = await fetch(TOKEN_ENDPOINT, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });

  const json = await response.json().catch(() => null);
  if (!response.ok || typeof json?.access_token !== "string") {
    throw new RelayError(
      502,
      "token_exchange_failed",
      json?.error_description ?? json?.error ?? `token endpoint returned HTTP ${response.status}`
    );
  }

  cachedToken = {
    value: json.access_token,
    expiresAt: now + (typeof json.expires_in === "number" ? json.expires_in : 3600),
  };
  return cachedToken.value;
}

export async function signAssertion(privateKeyPem, email, now) {
  const header = { alg: "RS256", typ: "JWT" };
  const claims = {
    iss: email,
    scope: SCOPE,
    aud: TOKEN_ENDPOINT,
    iat: now,
    exp: now + 3600,
  };

  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`;
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pkcs8DerFromPem(privateKeyPem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput)
  );
  return `${signingInput}.${base64urlFromBytes(new Uint8Array(signature))}`;
}

/// 服务账号 JSON 里的 private_key 是 PEM 包着的 PKCS#8。
/// 注意它带的是字面量 `\n`——从 JSON 复制到 wrangler secret 时若被转义成两个字符，
/// 这里要还原，否则 base64 解不出来。
function pkcs8DerFromPem(pem) {
  const body = pem
    .replace(/\\n/g, "\n")
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  if (body.length === 0) {
    throw new RelayError(500, "misconfigured", "GOOGLE_SA_PRIVATE_KEY is not a PKCS#8 PEM key");
  }
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

function base64url(text) {
  return base64urlFromBytes(new TextEncoder().encode(text));
}

function base64urlFromBytes(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function requireEnv(env, name) {
  const value = env[name];
  if (typeof value !== "string" || value.length === 0) {
    throw new RelayError(500, "misconfigured", `${name} is not set on the relay`);
  }
  return value;
}
