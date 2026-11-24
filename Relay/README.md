# 表匣 AI 中转服务（Relay）

基于 Node.js 20+ 的轻量 HTTP 中转服务，零第三方 npm 运行依赖，可直接本地运行或部署至阿里云函数计算（Function Compute 3.0）等无服务器环境。

## 核心接口与隐私边界

| 路由 | 用途 | 隐私说明 |
|---|---|---|
| `POST /v2/explain-fields` | 匿名表格字段含义解释（当前主入口） | 仅接收经用户核对的匿名字段标签、章节、说明与选项，不包含个人资料或具体答案 |
| `POST /v1/explain-fields` | 匿名表格字段含义解释（v1 兼容） | 同上，返回基础 canonical key 白名单或 `null` |
| `POST /v1/plan-form` | 整表与单空（含选项）填写建议（当前主入口） | 仅处理客户端按建档资料项权限显式构造的匿名来源片段，要求逐字证据校验 |
| `POST /v1/demo-access/status` | 查询演示访问凭证有效期与限流策略 | 仅返回凭证状态与每分钟配额信息，不触发模型调用 |
| `POST /v1/compose-answer` | 单空答案整理（旧版兼容保留） | 不再作为新版客户端主入口 |
| `POST /v1/resolve-fields` / `POST /v1/extract-profile` | 旧版客户端兼容端点 | 新版 App 不再调用；演示访问凭证默认禁止访问这两个端点 |

### 隐私与安全约束

- **最小化日志**：服务不记录请求正文、模型返回正文、个人资料或明文凭证；日志仅包含请求 ID、耗时、状态码、模型名、尝试次数、Token 用量及固定错误分类。
- **客户端侧权限控制**：个人资料项的 AI 可见开关与内容指纹保存在 iOS 客户端本机并在出站前校验；Relay 无法读取设备上的材料库或原文件。
- **严格校验与容错**：所有路由均启用 32 KB 请求体上限与严格 schema 白名单校验；`/v1/plan-form` 单批最多 8 个字段、20 个片段、单片段 8000 UTF-16 单元，且显式关闭思考模式（`thinking: { type: "disabled" }`）以保证 JSON 输出稳定与耗时可控。

## 本地运行与测试

需要 Node.js 20 或更高版本，无需安装第三方依赖：

```bash
cd Relay
cp .env.example .env
# 在运行环境中配置 DEEPSEEK_API_KEY 等变量
npm test
npm start
```

## 环境变量

| 变量名 | 是否必需 | 说明 |
|---|---|---|
| `DEEPSEEK_API_KEY` | 是 | 上游 DeepSeek API 密钥（仅配置在服务端，严禁提交到仓库） |
| `RELAY_CLIENT_TOKEN` | 视模式而定 | 共享客户端令牌（启用 `DEMO_ACCESS_CONFIG` 且 `ALLOW_SHARED_EXPLANATION=false` 时，新接口默认拒绝共享令牌） |
| `DEEPSEEK_BASE_URL` | 否 | 上游接口地址，默认 `https://api.deepseek.com` |
| `AI_PRIMARY_MODEL` | 否 | 主模型名称，默认 `deepseek-flash` |
| `AI_FALLBACK_MODEL` | 否 | 备用模型名称，默认 `deepseek-v4-pro` |
| `MODEL_TIMEOUT_MS` | 否 | 模型请求超时毫秒数，默认 `20000` |
| `PORT` | 否 | 本地监听端口，默认 `8787` |
| `DEMO_ACCESS_CONFIG` | 否 | 无数据库独立访问凭证配置 JSON：`{"enabled":false,"credentials":{}}` |
| `ALLOW_SHARED_EXPLANATION` | 否 | 是否允许共享令牌调用新接口，对外演示须保持 `false` |

## 独立演示凭证管理（无数据库）

面向自测与小范围试用，服务端无需 Redis 或数据库，仅在环境变量 `DEMO_ACCESS_CONFIG` 中保存凭证的 SHA-256 摘要、过期时间、撤销状态与每分钟限流值：

- 每分钟限流与单凭证并发限制在**单个服务进程**内生效（实例重启后重置，多实例间不共享），不等同于生产级全局配额或账单硬上限。
- 凭证文件以 `0600` 权限生成并由 `.gitignore` 忽略，请勿提交到 Git 仓库或在日志/终端中打印明文凭证。

从 `Relay/` 目录执行管理脚本：

```bash
# 签发独立凭证（示例有效期 30 天）
node scripts/demo-access.mjs issue /private/tmp/demo.demo-config.json https://your-relay.example /private/tmp/client-01.demo-access.json 30

# 启用、查看状态、续期、撤销、全局暂停
node scripts/demo-access.mjs enable /private/tmp/demo.demo-config.json
node scripts/demo-access.mjs status /private/tmp/demo.demo-config.json
node scripts/demo-access.mjs extend /private/tmp/demo.demo-config.json <凭证ID> 7
node scripts/demo-access.mjs revoke /private/tmp/demo.demo-config.json <凭证ID>
node scripts/demo-access.mjs disable /private/tmp/demo.demo-config.json
```

> 脚本仅修改本地配置文件，必须将更新后的配置同步到云端 `DEMO_ACCESS_CONFIG` 环境变量后才会生效。

## 无服务器部署（阿里云函数计算）

1. 在仓库根目录执行打包脚本生成仅包含服务源码的部署包与校验指纹：
   ```bash
   python3 Scripts/package-demo-relay.py
   ```
2. 函数运行时选择 **Node.js 20**，处理函数入口设置为 `index.handler`，建议函数超时时间不低于 90 秒（以覆盖整表接口最多两次模型尝试与网络传输）。
3. 在云端控制台配置环境变量（`DEEPSEEK_API_KEY`、`DEMO_ACCESS_CONFIG`、`ALLOW_SHARED_EXPLANATION=false` 等），不要将任何真实密钥写入源码包。
4. 如需紧急停用外部演示访问，可将 `DEMO_ACCESS_CONFIG` 中的 `enabled` 设为 `false` 发布生效。
