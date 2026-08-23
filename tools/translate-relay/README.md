# 译境翻译中转

一层薄薄的转发：验令牌 → 换 GCP access token → 调 Cloud Translation v3 → 回结果。
部署在 Cloudflare Workers。

**为什么要有它。** Cloud Translation v3 只接受 OAuth 令牌，不接受 API Key
（官方 `translateText` 的 Authorization Scopes 一栏只列了两个 OAuth scope）。
服务账号私钥不能跟着 App 分发，所以必须有个地方替 App 拿着它。

**为什么契约里没有"谷歌"。** 请求体没有任何 v3 特有的字段名，响应也不透传谷歌的结构。
后面想换成 Translation LLM 或别家引擎，改的是 `src/google.js`，客户端一行不动。

## 接口

```
POST /v1/translate
X-Verto-Token: <共享密钥>
Content-Type: application/json

{ "q": ["...", "..."], "source": "en" | null, "target": "zh-CN" }
```

`source` 传 `null` 或省略即自动检测，检测结果在响应里回。

```
200 → { "translations": [ { "text": "...", "detectedLanguage": "en" | null } ] }
```

`translations` 与 `q` 一一对应、顺序一致、长度必然相等——对不上时中转报
`upstream_malformed`，不会悄悄少还一条。

出错时：

```
4xx/5xx → { "error": { "code": "...", "message": "..." } }
```

| HTTP | code | 含义 |
|---|---|---|
| 400 | `bad_request` | 请求体不合契约 |
| 401 | `unauthorized` | 令牌缺失或不对 |
| 404 | `not_found` | 路径不对 |
| 405 | `method_not_allowed` | 不是 POST |
| 413 | `payload_too_large` | 超过 30K 码点（v3 单请求上限） |
| 413 | `too_many_segments` | `q` 超过 128 条 |
| 429 | `rate_limited` | 中转限流，或谷歌限流 |
| 4xx | `upstream_rejected` | 谷歌拒了：API 没启用、计费没开、服务账号缺角色。**重试无用** |
| 500 | `misconfigured` | 中转自己少配了 secret |
| 502 | `token_exchange_failed` | 换 access token 失败 |
| 502 | `upstream_error` / `upstream_malformed` | 谷歌 5xx 或回包不合预期。**可重试** |

还有 `GET /health` → `{ "ok": true }`，不需要令牌。

## 部署

### 1. GCP 侧

```bash
gcloud services enable translate.googleapis.com --project=<PROJECT_ID>

gcloud iam service-accounts create verto-relay \
  --display-name="Verto translate relay" --project=<PROJECT_ID>

gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --member="serviceAccount:verto-relay@<PROJECT_ID>.iam.gserviceaccount.com" \
  --role="roles/cloudtranslate.user"

gcloud iam service-accounts keys create key.json \
  --iam-account=verto-relay@<PROJECT_ID>.iam.gserviceaccount.com
```

**然后去控制台设配额上限**（APIs & Services → Cloud Translation API → Quotas）。
令牌是跟着 App 分发的，拆包就能拿到——账单的硬顶只能是这里，不是中转的限流。

原来那把限制成「iOS 应用」的 API Key 在 v3 这条路上用不上，可以删掉。

### 2. Cloudflare 侧

```bash
npx wrangler secret put GOOGLE_SA_EMAIL        # key.json 里的 client_email
npx wrangler secret put GOOGLE_SA_PRIVATE_KEY  # key.json 里的 private_key，整段照抄含 BEGIN/END
npx wrangler secret put GCP_PROJECT_ID         # key.json 里的 project_id
npx wrangler secret put VERTO_SHARED_TOKEN     # openssl rand -base64 32
npx wrangler deploy
```

填完把 `key.json` 删掉——它不需要留在本机，更不能进 Git。

### 3. 绑域名

`workers_dev = false` 是有意的：`*.workers.dev` 在中国大陆解析不了，
留着也只是一个自己用不上、别人却扫得到的入口。

在 Cloudflare 控制台把 Worker 的 route 指到你的子域（例如 `api.vertotranslate.com/*`），
或者把 `wrangler.toml` 里 `[[routes]]` 那两行的注释去掉再 deploy。

### 4. 接进 App

把域名和令牌填进仓库根目录的 `Secrets.xcconfig`（见根 README）。

## 本地开发

```bash
cp .dev.vars.example .dev.vars   # 填真值；.dev.vars 已被 gitignore
npx wrangler dev
```

冒烟：

```bash
curl -s localhost:8787/health

curl -s localhost:8787/v1/translate \
  -H "X-Verto-Token: $VERTO_SHARED_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"q":["Hello","Good morning"],"source":"en","target":"zh-CN"}'

# 没令牌应当 401
curl -s -o /dev/null -w '%{http_code}\n' localhost:8787/v1/translate \
  -H 'Content-Type: application/json' -d '{"q":["hi"],"target":"zh-CN"}'
```

## 测试

```bash
npm test
```

跑的是 `src/protocol.js` 的纯函数部分——契约校验、限额、响应整形、错误分类。
不需要 workerd，也不碰网络。签名换令牌和调 v3 这两段要靠 `wrangler dev` 真跑。

## 还没做的

**App Attest。** 现在的共享密钥挡得住随手扫到 URL 的人，挡不住拆 IPA 的人。
`src/auth.js` 的 `verifyCaller` 独占一层就是为了以后能整体换掉——
客户端契约仍是一个请求头，接的时候不必动 App 的调用代码。
