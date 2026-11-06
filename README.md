# 黄河图志

河南段黄河文化遗产的分布式数字档案，端侧优先的开源鸿蒙（OpenHarmony）应用。
参加 2026 第三届河南省高等学校信息技术应用创新大赛「开源鸿蒙」赛题一。

一句话概括技术取向：**内容全部装进设备，云只负责两件事 —— 个人数据的跨设备同步，与检索增强问答。**
飞行模式下首页、检索、图谱、详情全部可用；联网之后才多出「问它」和「换台设备接着看」。

## 它能做什么

| 能力 | 落点 | 说明 |
|---|---|---|
| 离线档案浏览 | 端侧 | 档案按时代轴组织，构建期把 YAML 编成 SQLite 预置包导入设备 |
| 全文检索 | 端侧为主，云侧增强 | 端侧 BM25 + 前向最大匹配分词；云侧加向量通道与重排 |
| 知识图谱 | 端侧 | 结构性边 + 条目间关系边，构建期预计算；移动端默认只画「一处遗址 + 一跳邻居」 |
| 关联推荐 | 端侧 | 内容相似度 × 行为画像（收藏与浏览时间衰减），理由用人话写清为什么推荐 |
| 问答 | 云侧 | RAG，答案带可点回的出处引用；无 AI Key 时降级为检索摘要 |
| 跨设备同步 | 云侧 + 分布式软总线 | 收藏、笔记、冲突记录；同用户多设备实时广播，LWW 收敛 |
| 笔记 | 端侧 | 支持 Markdown 子集，渲染与编辑同源 |

## 目录

```
harmony/YellowRiverArchive/   ArkTS 应用（端侧全部逻辑与数据）
apps/server/                  Fastify + SQLite 云侧服务（同步 / 检索 / 问答）
packages/data/                档案源数据：sites.yaml 清单 + sites/*.yaml 正文
packages/{shared,nlp,ai}/     三端共用的模型、分词、AI 适配
tools/pipeline/               构建期流水线：校验、分块、构图、预计算、导出预置包、封面卡
docs/                         设计文档、决策记录（ADR）、数据规范、构建说明
```

## 快速开始

环境：Node ≥ 20（pnpm workspace）、DevEco Studio 26 与其自带的 OpenHarmony SDK 26。

```bash
pnpm install
cp .env.example .env && pnpm env:init      # AI 供应商密钥（不配也能跑，检索退为纯关键词）

pnpm data:status        # 只校验数据与分布，不写文件
pnpm data:build         # 生成端侧预置包（items / chunks / graph / similar / vocab）
pnpm data:covers        # 生成遗址封面卡（程序化示意图，见下）
pnpm server             # 本地起云侧服务，默认 8787
```

应用侧：

```bash
cd harmony/YellowRiverArchive
devecocli check arkts                      # ArkTS 静态检查
devecocli build                            # 交付用：OpenHarmony unsigned HAP
../tools/sign-openharmony.sh               # 用 SDK 自带测试证书签名
devecocli build --product harmony          # 真机自测用：HarmonyOS 签名包
```

两个 product 并存是刻意的：OpenHarmony 证书能装模拟器与开源鸿蒙设备，但华为真机会拒装（code:9568257）。
细节与踩坑记录见 [`docs/开源鸿蒙构建说明.md`](docs/开源鸿蒙构建说明.md)。

## 数据从哪来、怎么保证不是编的

`packages/data/sites.yaml` 是台账（清单、优先级、置信度、出处），`packages/data/sites/*.yaml` 是正文。

写正文有一条硬门禁：**`pnpm data:draft` 只给已有来源摘录的条目起草** —— 缺 `packages/data/sources/<id>.md` 就直接跳过，不生成。
这是 ADR-022 的设定，宁可少几条，也不要「看起来对但查不到出处」的内容。
`pnpm data:lint` 另有 n-gram 查重、字数区间、版权留痕、时代轴空洞等检查，硬错误会让 pre-push 钩子拦下提交。

封面图同样是「不编」的：`tools/pipeline/src/covers.ts` 从元数据确定性渲染示意图（时代矿物色带 + 类型线描符号 + 宋体遗址名），不用模型生图 —— 模型画的文物造型可能与正文不符。
因此这些图的版权天然干净（本项目绘制）。

## 云侧部署

单台 2C2G，systemd 拉起服务，openresty 反代并终止 TLS。部署包与自检清单在 `submission/`，
说明见 [`submission/部署说明.md`](submission/部署说明.md)。

一个容易踩的坑记在这里：反代 WebSocket 时 `proxy_set_header Connection $http_connection` 在 HTTP/2 下取值为空，
升级请求头丢失，`/ws/sync` 返回 404。写死 `Connection "upgrade"` 才对。

## 文档入口

- [`docs/README.md`](docs/README.md) —— 文档索引
- [`docs/设计文档.md`](docs/设计文档.md) —— 架构与取舍
- [`docs/decisions.md`](docs/decisions.md) —— 决策记录（ADR-001 起）
- [`docs/data-spec.md`](docs/data-spec.md) —— 数据规范
- [`docs/开源鸿蒙构建说明.md`](docs/开源鸿蒙构建说明.md) —— 平台差异、签名、踩坑表

## 许可

代码采用 Apache-2.0（见 `LICENSE`）。
思源宋体字体遵循 SIL Open Font License 1.1，保留在 `harmony/YellowRiverArchive/entry/src/main/resources/rawfile/fonts/OFL.txt`。
档案正文与示意图的版权与出处逐条登记在 `packages/data/`，不随代码许可自动授权。
