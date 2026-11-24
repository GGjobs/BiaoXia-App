# 表匣（BiaoXia）

> 表匣是一个面向 iOS 18+ 的原生应用（当前为演示型 MVP），支持在本机将 PDF、图片与原生 DOCX 个人材料整理为结构化个人档案，并对支持范围内的文字 PDF 与原生 DOCX 空白表进行本地匹配、可选授权的 AI 辅助填写、人工核对与原格式导出。

## 核心工作流

```text
PDF / DOCX / 图片材料本地建档
  → 核对与维护个人档案
  → 导入 PDF / DOCX 空白表
  → 本地规则匹配 + 可选授权 AI 建议 + 人工核对
  → 按原格式生成并导出新文件
```

## 主要特性

### 1. 本机建档与资料库管理
- **全本地识别**：PDF 文本层提取、Vision OCR（扫描件与图片）以及原生 `.docx` 正文段落与表格提取全部在本机完成，提取原文支持搜索。
- **多类别档案与人物归属**：支持基础身份、联系方式、学籍、教育、工作、项目、课程、技能、证书、奖项、经历及人物关系（本人、紧急联系人、家属等），保留候选冲突与人工确认流程。
- **本地文件保护与恢复**：SwiftData 仅保存任务列表元数据；个人材料库存放在 `Application Support/BiaoXia/Profile`，填表任务存放在 `Application Support/BiaoXia/Tasks`，两者均启用系统文件保护，并在导入、解析、匹配、核对及导出阶段保存可恢复检查点。

### 2. PDF 与原生 DOCX 填写及导出
- **通用文字 PDF**：对可读、未加密、具备文本层且答案位置可可靠定位的 PDF 进行动态字段识别、本地匹配、集中确认与回写导出；支持位置查看/框选修正与字段补充；扫描/混合、旋转、受保护或结构含糊的文件会明确阻断。
- **原生 DOCX**：支持普通表格相邻单段空格、带标签的 `{{占位符}}` / 连续下划线、同段明确方框勾选组；保留原有结构、样式和预填内容，支持跨 run 占位符与多行文字，导出可编辑 `.docx`（最终排版、分页与行高需在 Word/WPS 中复核）。纵向合并格、嵌套表格、浮动文本框、复杂域、修订、宏及受保护文档会明确拒绝，不支持旧 `.doc`。
- **导出前核对**：导出页区分已确认、明确留空与未处理字段，存在未处理项时会要求显式确认部分导出；原文件始终保持不变。

### 3. 按建档资料项控制 AI 可见范围
- **默认关闭、逐项授权**：在「我的信息」或 AI 填写页打开「AI 可用资料」，逐项允许已保存且非待确认的建档资料。新增资料默认关闭；授权绑定条目内容与人物归属指纹，内容变动后需重新允许。
- **最小化构造出站内容**：整表与单空（含选项）共用 `/v1/plan-form`，发送内容仅由允许条目的标签、内容及匿名人物标识（如「本人」「家属 1」）重新构造；结构化组成、人物表姓名、材料文件名、来源原文、完整 OCR 与原文件不自动附带。
- **发送前逐轮核对**：字段解释使用 `/v2/explain-fields`，不发送个人答案；AI 填写整表/单空发送前展示拟发送资料与字段要求，支持本轮取消部分勾选，返回结果经本人核对采用后才写入。未开启 AI 权限、无网络或未配置中转服务时，仍可完整使用本地匹配、手动填写与导出。

## 技术栈与工程结构

- **iOS 客户端**：Swift 6、SwiftUI、Observation、SwiftData、Vision、PDFKit（零第三方 Swift Package 依赖）
- **AI 中转服务（Relay）**：Node.js 20+ 原生 HTTP 服务（零第三方 npm 运行依赖）

```text
BiaoXia/               iOS 应用源码
  App/                  应用入口与流程状态机
  Core/                 领域模型、材料库、档案、SwiftData 元数据与任务存储
  Services/             OCR、PDF/DOCX 解析与回写引擎、本地匹配、授权 AI 服务
  Features/             材料建档、档案确认、空表导入、填写核对与导出预览
  Resources/            示例模板 manifest 与空白表资源
BiaoXiaTests/           字段解析、隐私权限、坐标与引擎单元测试
BiaoXiaUITests/         文件导入、填写与任务管理 UI 测试
Config/                 Info.plist 配置
Relay/                  Node.js 20 AI 中转服务与单元测试（见 Relay/README.md）
Scripts/                虚构测试样本生成、DOCX 引擎回归与辅助脚本
TestAssets/             虚构演示与测试样例（不打包进 App）
Secrets.xcconfig.example  本机调试配置示例（真实 Secrets.xcconfig 由 Git 忽略）
```

## 快速开始

### 运行 iOS 应用

1. 使用支持 Swift 6 与 iOS 18+ 的 Xcode 打开 `BiaoXia.xcodeproj`，选择 `BiaoXia` scheme。
2. 在 **Signing & Capabilities** 中选择您自己的开发团队（仓库不含签名凭证）。
3. 选择 iOS 18 或更高版本的模拟器或真机运行。
4. 首次启动为空信息库，可使用 `TestAssets/` 中的虚构示例材料建档并体验本地匹配、填写与导出流程。
5. 如需启用云端 AI 字段解释或填写建议，可在首页「演示访问」中填入自建 Relay 的 HTTPS 地址与访问凭证（存入本机 Keychain，不会嵌入安装包）；不配置云端也可完整使用离线流程。

### 运行 Relay 中转服务（可选）

详见 [Relay/README.md](Relay/README.md)。本地启动示例：

```bash
cd Relay
cp .env.example .env
# 在环境变量中配置 DEEPSEEK_API_KEY 等参数后运行：
npm test
npm start
```

## 构建与测试

```bash
# Relay 单元测试（Node.js 20+）
cd Relay && npm test

# 本地 DOCX 引擎独立回归（无需启动模拟器）
bash Scripts/verify_docx_engine.sh /tmp/biaoxia-docx-checks

# iOS 模拟器构建
xcodebuild \
  -project BiaoXia.xcodeproj \
  -scheme BiaoXia \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro Max' \
  build

# 无签名 Release 真机构建检查
xcodebuild \
  -project BiaoXia.xcodeproj \
  -scheme BiaoXia \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

> 如需重新生成 `TestAssets/` 中的虚构演示样例（需 Python 3、ReportLab、Pillow）：
> ```bash
> python3 Scripts/generate_demo_assets.py
> ```
> 通用表格虚构测试集说明见 [TestAssets/GeneralForms/README.md](TestAssets/GeneralForms/README.md)。

## 当前边界与说明

- 当前版本尚未包含相机实时扫描、用户账号体系、iCloud/多端同步、云端资料库或网页表单自动提交。
- 本项目定位为演示型 MVP，未完成面向公开大规模分发的生产运维与全量真机兼容性验收；部署至生产环境前请自行完成签名、安全评估、限流计费与兼容性测试。

## 许可协议与商业授权

本项目采用 **PolyForm Noncommercial License 1.0.0**（非商业源码可用协议）+ **商业授权** 的双许可模式：

- **非商业用途（免费）**：个人学习、研究、测试、业余项目，以及协议定义的非商业组织（如教育机构、公益慈善、公共科研、政府机构等）的非商业用途，可按 [LICENSE](LICENSE) 免费使用、修改与分发。分发时须保留协议文本（或其链接）以及 [NOTICE](NOTICE) 中的全部 `Required Notice:` 声明。
- **商业用途（须付费授权）**：任何超出上述非商业范围的用途——包括但不限于直接或间接收费、集成到商业产品或企业内部业务系统、打包上架 App Store 或其他应用商店进行商业分发/变现、基于本项目提供付费部署或外包服务等——均**须事先向著作权人 GGjobs 购买书面商业授权**。
- **获取商业授权**：请前往本仓库 [GitHub Issues](https://github.com/GGjobs/BiaoXia-App/issues) 提交标题包含「商业授权咨询」的 Issue，说明您的使用场景、主体信息及期望的沟通渠道，著作权人将在确认后与您对接。
- **参与贡献（CLA）**：向本仓库提交 Pull Request 前请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。为保证项目可继续对外提供商业授权，提交贡献即视为您同意该文件中的贡献者许可协议条款。

> `Required Notice: Copyright (c) 2026 GGjobs (https://github.com/GGjobs/BiaoXia-App)`
