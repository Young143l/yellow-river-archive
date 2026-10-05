# 开发 TODO

> **执行级清单**，按顺序做即可。阶段看板见 [board.md](./board.md)（那里是里程碑级），本文是任务级与执行顺序。
> 规则：做完一项就把 `[ ]` 改成 `[x]`；卡住超过 1 天写进 board.md 的阻塞区。
> 依赖标记：`←` 后面的编号表示必须先完成的任务。

---

## D0 地基（先让工程跑起来）

| # | 任务 | 产出 | 依赖 |
|---|---|---|---|
| D0-1 | `git init` + `.gitignore` + `.githooks/` + `core.hooksPath` 配置 | 本地仓库与钩子生效 | — |
| D0-2 | 初始化 pnpm workspace（根 `package.json` / `pnpm-workspace.yaml` / 共享 tsconfig） | `pnpm install` 可跑 | D0-1 |
| D0-3 | `packages/shared`：`HeritageItem` 的 Zod schema（20 字段） | `models/heritage-item.ts` | D0-2 |
| D0-4 | `packages/shared`：常量枚举（5 城 / 6 时代 / 类型 / 标签 / 错误码） | `constants/*.ts` | D0-2 |
| D0-5 | `packages/shared`：API 类型（search / qa / graph / sync / backup 的请求响应） | `api/*.ts` | D0-3 |
| D0-6 | `tools/gen`：TS → ArkTS 类型生成脚本，并生成一次 | `.ets` 类型文件（带「自动生成」头） | D0-3 |
| D0-7 | 建鸿蒙工程 `YellowRiverArchive`（`com.yellowriver.archive`，`compatibleSdkVersion` = 17） | DevEco 工程可构建 | D0-2 |
| D0-8 | 工程目录规范落地：`pages/ components/ model/ service/ utils/ constants/` | 空目录与占位文件 | D0-7 |
| D0-9 | 底部 Tab 路由骨架（首页 / 检索 / 图谱 / 助手 / 我的），每页一个占位 | 可运行的空壳 App | D0-8 |
| D0-10 | 签名配置：`devecocli auth login` → `signature generate` → `devecocli run` 上真机 | 真机能跑空壳 | D0-9 |

**出口**：`devecocli run` 输出 `Smoke: PASS`；`packages/shared` 的类型两端都能引到。

---

## D0-V 技术验证（四个 spike，必须做完才进 D1）

| # | 任务 | 验证什么 | 结论去向 |
|---|---|---|---|
| D0V-1 | `distributedKVStore` 单机读写 + 自环同步 | API 可用性、数据模型约束 | `decisions.md` 追加 ADR |
| D0V-2 | RDB 建表 + 从 rawfile 导入 1000 条假数据 | 首启耗时与内存（是否需进度条/分片） | 同上 |
| D0V-3 | Canvas 力导向渲染 200 节点 | 帧率是否 ≥45fps（决定图谱节点上限） | 同上 |
| D0V-4 | rawfile 加载 50 张 WebP | 加载耗时与内存（决定图片尺寸策略） | 同上 |
| D0V-5 | 整理四个结论，更新受影响的方案章节 | 设计文档同步 | — |

**出口**：四项都有明确结论；如某项不达标，先改方案再往下走。

---

## D1 垂直切片（用 5 条数据打通端侧）

| # | 任务 | 产出 | 依赖 |
|---|---|---|---|
| D1-1 | 手写 5 条样例档案（覆盖 5 城中的 4 城、含五层内容） | `packages/data/sites/*.yaml` | D0-3 |
| D1-2 | 定稿端侧预置包格式 + 打包脚本 | `tools/pipeline/export.ts` 可产出预置包 | D1-1 |
| D1-3 | 端侧 model 层：RDB 表结构定义（条目 / 分块 / 图谱 / 相似度） | `model/schema.ets` | D1-2 |
| D1-4 | 首启导入逻辑（含进度提示与失败重试） | `service/DataImportService.ets` | D1-3, D0V-2 |
| D1-5 | DAO 封装：列表 / 详情 / 按维度筛选 / 全文匹配 | `service/HeritageDao.ets` | D1-4 |
| D1-6 | 端侧关键词检索：词典最大匹配 + 原文子串兜底 | `service/SearchService.ets` | D1-5 |
| D1-7 | 首页：时代轴滑动切换 + 条目卡片流 | `pages/HomePage.ets` | D1-5 |
| D1-8 | 检索页：关键词输入 + 三维筛选 chip + 结果列表 | `pages/SearchPage.ets` | D1-6, D1-7 |
| D1-9 | 详情页：六 Tab（图文 / 考古 / 事件 / 诗词 / 文旅 / 图谱） | `pages/DetailPage.ets` | D1-5 |
| D1-10 | 真机验证：飞行模式下浏览 5 条并检索 | 测试记录 | D1-7 ~ D1-9 |

**出口**：飞行模式全流程可用，无崩溃。

---

## D2 数据工程（可与 D3 并行）

| # | 任务 | 产出 | 依赖 |
|---|---|---|---|
| D2-1 | 联网核实 80 条清单（城市 / 年代 / 类型 / 级别 / 坐标） | `packages/data/sites.yaml` | — |
| D2-2 | 写 `docs/data-spec.md`（字段 / 字数 / 来源 / 改写红线 / 图片规范 / 分工） | 数据规范 | D2-1 |
| D2-3 | `tools/pipeline/chunk.ts`：语义分块（300-500 字，overlap 60） | 分块产物 | D2-1 |
| D2-4 | `tools/pipeline/tokenize.ts`：jieba 分词 + 自定义词典 + 词表导出 | `tokens` 与 `vocab.json` | D2-3 |
| D2-5 | `tools/pipeline/embed.ts`：批量 + 并发 + 退避重试 + sha256 缓存 + 断点续跑 | 向量文件 | D2-3 |
| D2-6 | `tools/pipeline/graph.ts`：三元组生成 + 实体归一化 | `graph.json` | D2-1 |
| D2-7 | `tools/pipeline/similar.ts`：条目间 top-20 相似度预计算 | `similar.json` | D2-5 |
| D2-8 | `tools/pipeline/lint.ts`：schema / 字数 / license / 分布 / n-gram 查重 | 质检报告 | D2-1 |
| D2-9 | `tools/pipeline/draft.ts`：AI 起草流水线（输出草稿，禁止直入库） | 草稿产出 | D2-2 |
| D2-10 | 首批 20 条：来源摘录 → 起草 → 改写 → 交叉校对 | 20 条终稿 | D2-9 |
| D2-11 | 图片采集：80 张主图，压缩转 WebP，登记 license 台账 | `assets/img/` + `license.md` | D2-10 |
| D2-12 | 剩余 60 条按城市包干完成 | 80 条终稿 | D2-10 |
| D2-13 | 全量质检 + 入库导出（端侧包 + 服务端索引） | 两份产物 | D2-12, D2-8 |

**出口**：80 条通过质检，license 齐全，端侧包 ≤55MB。

---

## D3 后端与检索

| # | 任务 | 产出 | 依赖 |
|---|---|---|---|
| D3-1 | `apps/server` 骨架：Fastify + pino + Zod + env 加载 + `/api/health` | 服务可启动 | D0-2 |
| D3-2 | provider 层：`EmbeddingProvider`（百炼） | `ai/embedding/` | D3-1 |
| D3-3 | provider 层：`RerankProvider`（百炼） | `ai/rerank/` | D3-1 |
| D3-4 | provider 层：`LlmProvider`（DeepSeek，流式） | `ai/llm/` | D3-1 |
| D3-5 | 连通性与限额实测脚本 + 记录 | `docs/ai-providers.md` | D3-2 ~ D3-4 |
| D3-6 | 服务端数据导入：chunk 文本 + FTS5 索引 + 向量索引 + 图谱表 | `data/import.ts` | D2-13, D3-1 |
| D3-7 | `/api/items`、`/api/items/:id`、`/api/items/:id/related` | 只读接口 | D3-6 |
| D3-8 | `/api/search` BM25 版（含维度过滤） | 关键词检索 | D3-6 |
| D3-9 | 查询理解：实体词典识别（5 城 / 6 时代 / 类型 / 别名） | `search/query-understanding.ts` | D0-4 |
| D3-10 | `/api/search` 混合检索版：向量 + RRF + 过滤 | 语义检索 | D3-8, D3-2 |
| D3-11 | 接入 Rerank，形成完整检索链 | 检索链定稿 | D3-10, D3-3 |
| D3-12 | 调用统计（token / 次数 / 耗时）落表 + `/api/stats/usage` | 成本可观测 | D3-5 |

**出口**：混合检索明显优于纯关键词；调用有统计。

---

## D4 收藏笔记与分布式同步

| # | 任务 | 产出 | 依赖 |
|---|---|---|---|
| D4-1 | 端侧个人数据表：收藏（遗址+文物统一）/ 笔记 / 标签 / 进度 | `model/schema.ets` | D1-3 |
| D4-2 | 收藏 / 笔记 / 标签 的 UI 与交互 | 详情页与我的档案页 | D4-1 |
| D4-3 | 学习进度计算（去重条目 / 总数，按时代分段） | `service/ProgressService.ets` | D4-1 |
| D4-4 | `SyncAdapter` 接口定义 | `service/sync/types.ets` | D4-1 |
| D4-5 | `HarmonyDistributedKV` 实现（主路径） | `service/sync/distributed.ets` | D4-4, D0V-1 |
| D4-6 | 服务端同步服务（WS + LWW + 变更日志 + 冲突日志） | `apps/server/src/sync/` | D3-1 |
| D4-7 | `CloudSync` 端侧实现（兜底通道） | `service/sync/cloud.ets` | D4-4, D4-6 |
| D4-8 | `IdentityAdapter` + 配对码页面（openid 主 / 配对码兜底） | `service/identity/` | D4-4 |
| D4-9 | 同步中心页：进度（n/m + 方向）/ 冲突列表 / 手动同步 | `pages/SyncPage.ets` | D4-5, D4-7 |
| D4-10 | 备份恢复：导出 / 导入合并 / 云端快照 | 接口 + UI | D4-6 |
| D4-11 | 双端冲突联调（两端离线改同一条 → 按最新时间戳收敛） | 测试记录 | D4-9 |

**出口**：冲突可见并正确收敛；备份可跨设备恢复。

---

## D5 AI 助手

| # | 任务 | 产出 | 依赖 |
|---|---|---|---|
| D5-1 | 图谱 API：`subgraph` / `path` / `communities` / `theme/build` | 图谱接口 | D3-6 |
| D5-2 | 图算法：PageRank / 标签传播 / BFS 最短路 | `graph/algorithms.ts` | D5-1 |
| D5-3 | 问答 API：WS 流式 + 引用数组 + 图谱路径 + 四级降级 | `api/qa` | D3-11, D3-4 |
| D5-4 | AI 助手页：流式输出 + 引用卡片跳详情 + 图路径展示 | `pages/AssistantPage.ets` | D5-3 |
| D5-5 | 断网降级验证（拔网线 → 抽取式回答 + 端侧检索仍可用） | 测试记录 | D5-4 |

**出口**：引用可点击跳转；断网仍给出带引用的答案。

---

## D6 图谱可视化与知识库

| # | 任务 | 产出 | 依赖 |
|---|---|---|---|
| D6-1 | 力导向布局引擎（网格桶近似） | `utils/force-layout.ets` | D0V-3 |
| D6-2 | 图谱页面：节点按类型着色、大小按 PageRank、边按关系区分线型 | `pages/GraphPage.ets` | D6-1, D5-1 |
| D6-3 | 时间轴联动（拖动时代轴高亮对应节点） | 交互实现 | D6-2 |
| D6-4 | 聚类动画（新主题生成时节点向簇心收拢） | 动画实现 | D6-3, D5-2 |
| D6-5 | 个人知识图谱 + 自动主题生成 | 个人图谱视图 | D5-2, D4-2 |

**出口**：收藏 10 条后一键生成主题簇并动画展开。

---

## D7 收尾与联调

| # | 任务 | 产出 | 依赖 |
|---|---|---|---|
| D7-1 | 我的档案页完整版：收藏 / 笔记 / 标签 / 进度 / **文档视图（可导出）** | `pages/ProfilePage.ets` | D4-2, D6-5 |
| D7-2 | 多端协同编辑：笔记补充 / 修改 / 合并 / 排序 | 编辑能力 | D4-9 |
| D7-3 | 关于页：数据源与版权声明 | `pages/AboutPage.ets` | — |
| D7-4 | 端侧预置包体积优化（图片压到预算内） | 包体 ≤55MB | D2-13 |
| D7-5 | 端到端联调 + 性能实测（冷启动 / 检索 / 问答首字 / 图谱帧率 / 服务器内存） | 测试记录（写入设计文档 §13） | 全部 |
| D7-6 | 断网全流程演练（作为路演保命预案） | 演练记录 | D7-5 |

**出口**：全部功能在真机上跑通，性能指标达标。

---

## 执行顺序总览

```
D0 地基 → D0-V 验证 → D1 垂直切片 → ┬→ D3 后端 → D4 同步 → D5 AI → D6 图谱 → D7 收尾
                                     └→ D2 数据工程（并行，长尾）
```

**关键提醒**

1. **D0-V 不可跳过**——四个验证决定后面所有设计，尤其是 D0V-1（分布式可行性）直接决定路演演示方案
2. **D1 只用 5 条数据**——不要等 80 条写完才动手，数据工程是长尾
3. **D2 与 D3 可并行**，但都依赖 D0-3 的契约冻结
4. **每完成一个 D 阶段**，回 [board.md](./board.md) 更新状态并在 [决策日志](./decisions.md) 记录新决策
