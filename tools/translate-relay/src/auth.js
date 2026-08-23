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

import { RelayError } from "./protocol.js";

export const CALLER_TOKEN_HEADER = "X-Verto-Token";

/// 「这个请求是不是我的 App 发的」独占一层，就为了以后能整体换掉。
///
/// 今天是共享密钥：能挡住随手扫到 URL 的人，挡不住拆 IPA 的人——令牌跟着包分发，
/// 拆出来就能用。所以账单的硬顶始终是 GCP 那边的配额上限，不是这里。
///
/// 以后要接 App Attest，只需在这里加一个分支：客户端改发 assertion，
/// 这里验苹果证书链、核 appID 哈希、核计数器防重放。**客户端契约仍是一个请求头**，
/// 所以那次改动不必动 App 的调用代码。
export async function verifyCaller(request, env) {
  const expected = env.VERTO_SHARED_TOKEN;
  if (typeof expected !== "string" || expected.length === 0) {
    // 配错了要吼出来，而不是变成"谁都能调"。
    throw new RelayError(500, "misconfigured", "VERTO_SHARED_TOKEN is not set on the relay");
  }

  const presented = request.headers.get(CALLER_TOKEN_HEADER);
  if (typeof presented !== "string" || !constantTimeEqual(presented, expected)) {
    throw new RelayError(401, "unauthorized", "caller token missing or wrong");
  }
}

/// 逐字节全比完再返回，不在第一个不同处短路——短路的比较会把
/// "前几位对了" 泄漏成响应时间差，可以被逐位试出来。
/// 长度不同直接返回是可以的：令牌长度本就不是秘密。
function constantTimeEqual(lhs, rhs) {
  const encoder = new TextEncoder();
  const a = encoder.encode(lhs);
  const b = encoder.encode(rhs);
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let index = 0; index < a.length; index += 1) difference |= a[index] ^ b[index];
  return difference === 0;
}
