# 开发 TODO

> **执行级清单**，按顺序做即可。阶段看板见 [board.md](./board.md)（那里是里程碑级），本文是任务级与执行顺序。
> 规则：做完一项就把 `[ ]` 改成 `[x]`；卡住超过 1 天写进 board.md 的阻塞区。
> 依赖标记：`←` 后面的编号表示必须先完成的任务。

---

## 进度总览

| 阶段 | 已完成 | 总计 | 状态 |
|---|---|---|---|
| D0 地基 | 10 | 10 | **完成** |
| D0-V 技术验证 | 5 | 5 | **完成**（跨设备同步待第二台设备补验） |
| D1 垂直切片 | 10 | 10 | **完成** |
| D2 数据工程 | 9 | 13 | 技术任务完成，待团队产出内容 |
| D3 后端与检索 | 10 | 12 | 检索链定稿 |
| D4 同步 | 0 | 11 | 未开始 |
| D5 AI 助手 | 0 | 5 | 未开始 |
| D6 图谱可视化 | 0 | 5 | 未开始 |
| D7 收尾 | 0 | 6 | 未开始 |

**最近一次更新**：2026-10-05

---

## D0 地基（先让工程跑起来）

| # | 任务 | 产出 | 依赖 | 状态 |
|---|---|---|---|---|
| D0-1 | `git init` + `.gitignore` + `.githooks/` + `core.hooksPath` 配置 | 本地仓库与钩子生效（已实测拦截密钥） | — | 完成 |
| D0-2 | 初始化 pnpm workspace（根 `package.json` / `pnpm-workspace.yaml` / 共享 tsconfig） | `pnpm install` 可跑 | D0-1 | 完成 |
| D0-3 | `packages/shared`：`HeritageItem` 等模型的 Zod schema | `src/models.ts` + `src/schemas.ts`（含编译期一致性断言） | D0-2 | 完成 |
| D0-4 | `packages/shared`：常量（5 城 / 6 时代 / 类型 / 标签 / 错误码） | `src/constants.ts` | D0-2 | 完成 |
| D0-5 | `packages/shared`：API 类型（items / search / qa / graph / sync / backup / stats） | `src/api.ts` + `src/preset.ts` | D0-3 | 完成 |
| D0-6 | `tools/gen`：TS → ArkTS 类型生成器（逐字复制 + 生成头，带 `--check` 模式） | `tools/gen/src/index.ts` | D0-3 | 完成 |
| D0-7 | 建鸿蒙工程 `YellowRiverArchive`（`com.yellowriver.archive`，`compatibleSdkVersion` = 5.0.5(17)） | DevEco 工程可构建 | D0-2 | 完成 |
| D0-8 | 工程目录规范落地：`pages/ components/ model/ service/ utils/ constants/ shared/` | 目录与占位文件 | D0-7 | 完成 |
| D0-9 | 底部 Tab 路由骨架（首页 / 检索 / 图谱 / 助手 / 我的） | 可运行的空壳 App（`devecocli build` 成功） | D0-8 | 完成 |
| D0-10 | 签名配置：`devecocli auth login` → `signature generate` → `devecocli run` 上真机 | 真机能跑空壳 | D0-9 | 完成（华为畅享 90 Pro Max，`Smoke: PASS`） |

**出口**：`devecocli run` 输出 `Smoke: PASS` ✓；`packages/shared` 的类型两端都能引到 ✓。**D0 阶段已全部完成。**

> 验证记录：真机 华为畅享 90 Pro Max（API 26），应用安装并启动成功，五个 Tab 正常渲染（截图存本地 `.shots/d0-tab.png`）。
>
> 签名材料由 `devecocli signature generate` 生成，写入 `build-profile.json5`（加密密码）与 `~/.ohos/config/`（证书）。**其他队友首次构建前需自己跑一次 `devecocli auth login` + `signature generate`**，因为证书是绑定账号与本机路径的。

> D0 已提前完成的一件事：发现端侧 ArkTS 是 TypeScript 的**子集**，据此重写了共享契约（见 [决策日志 ADR-019](./decisions.md)），42 个编译错误归零。

---

## D0-V 技术验证（已完成）

测试设备：华为畅享 90 Pro Max（API 26）。完整结论见 [决策日志 ADR-020](./decisions.md)。

| # | 验证 | 实测结果 | 状态 |
|---|---|---|---|
| D0V-1 | `distributedKVStore` 本地读写 / 前缀遍历 / 删除 | 通过（首次 574ms 含初始化，后续 79ms） | 完成 |
| D0V-1b | **跨设备同步** | 需要第二台可信设备 | **待补验**（看板 B1） |
| D0V-2 | RDB 批量写入 1000 条 + 扫描 + 条件查询 | 通过（写入 **50ms**，全表扫描 0ms） | 完成 |
| D0V-3 | Canvas 力导向 200 节点 / 300 连边 | 通过（**6.57ms/帧**，折算 152fps） | 完成 |
| D0V-4 | rawfile 串行读取 50 张 WebP（6.5MB） | 通过（总耗 **11ms**） | 完成 |
| D0V-5 | 结论整理与方案回写 | ADR-020 + 本节 | 完成 |

**四项结论对设计的直接影响**

1. **首启导入不需要进度条**——全量约 1500 chunk 预计 100ms 内完成
2. **图片尺寸策略维持**——230 张读取约 100ms，体积约束来自安装包大小而非性能
3. **力导向仅在 200-300 节点内可保 60fps**——斥力是 O(n²)，推算 500 节点约 35ms/帧，**必须启用网格桶近似**
4. **distributedKVStore 可用**——读写均为毫秒级，足以承载个人数据

> 验证代码：`service/DevProbe.ets`、`utils/ForceProbe.ets`，验证完成后可整体删除。

**出口**：四项都有明确结论；如某项不达标，先改方案再往下走。✓ 已达成

---

## D1 垂直切片（已完成）

| # | 任务 | 产出 | 状态 |
|---|---|---|---|
| D1-1 | 手写 5 条样例档案 | `packages/data/sites/*.yaml`（覆盖 5 城、多个时代与类型） | 完成 |
| D1-2 | 定稿预置包格式 + 打包脚本 | `tools/pipeline`（load-sites / chunk / graph / similar / export） | 完成 |
| D1-3 | RDB 表结构定义 | `model/Schema.ets`（6 张表 + 6 个索引） | 完成 |
| D1-4 | 首启导入逻辑 | `service/DataImportService.ets`（幂等、事务、并发安全） | 完成 |
| D1-5 | DAO 封装 | `service/HeritageDao.ets`（内存缓存 + 筛选 + 关联推荐） | 完成 |
| D1-6 | 端侧关键词检索 | `service/SearchService.ets`（字段打分 + 正文子串兜底） | 完成 |
| D1-7 | 首页时间轴 | `pages/HomePage.ets`（六时代轴 + 卡片流） | 完成 |
| D1-8 | 检索页与三维筛选 | `pages/SearchPage.ets` | 完成 |
| D1-9 | 详情页六 Tab | `pages/DetailPage.ets`（路由跳转） | 完成 |
| D1-10 | 真机/模拟器验证 | 截图存 `.shots/` | 完成 |

**出口**：飞行模式下能浏览 5 条并完成关键词检索，UI 无崩溃。✓ 已达成

> D1 期间发现并修复一个隐蔽 Bug：ArkTS 的 `@Builder` 按值传参不具响应性，导致筛选 chip 选中态与实际筛选条件脱节（详见 [ADR-021](./decisions.md)）。

---

## D2 数据工程（可与 D3 并行）

| # | 任务 | 产出 | 状态 |
|---|---|---|---|
| D2-1 | 核实 80 条清单（城市 / 年代 / 类型 / 级别） | `packages/data/sites.yaml` + `pnpm data:sites` 体检命令 | 完成（置信度已标注，逐项核对待人工） |
| D2-2 | 写 `docs/data-spec.md`（字段 / 字数 / 来源 / 改写红线 / 图片规范 / 分工与核对） | 数据规范 | 完成 |
| D2-3 | `tools/pipeline/chunk.ts`：语义分块 | 分块产物 | **D1-2 已完成** |
| D2-4 | `tools/pipeline/tokenize.ts`：jieba 分词 + 自定义词典 + 词表导出 | `tokens` 与 `vocab.json` | 完成（jieba + 领域词典最大匹配；端侧同套词表） |
| D2-5 | `tools/pipeline/embed.ts`：批量 + 并发 + 退避重试 + sha256 缓存 + 断点续跑 | 向量文件 | 完成（缓存生效，零重复计费） |
| D2-6 | `tools/pipeline/graph.ts`：三元组生成 + 实体归一化 | `graph.json` | **D1-2 已完成基础版** |
| D2-7 | `tools/pipeline/similar.ts`：条目间 top-20 相似度预计算 | `similar.json` | **D1-2 已完成基础版**（待并入向量相似度） |
| D2-8 | `tools/pipeline/lint.ts`：schema / 字数 / license / 分布 / n-gram 查重 | 质检报告 | **已完成**（查重自测命中 83 字重合） |
| D2-9 | `tools/pipeline/draft.ts`：AI 起草流水线（输出草稿，禁止直入库） | 草稿产出 | **已完成**（实测产出结构完整草稿） |
| D2-10 | 首批 20 条：来源摘录 → 起草 → 改写 → 交叉校对 | 20 条终稿 | **待团队**（工具链已就绪，已写 5 条样例） |
| D2-11 | 图片采集：80 张主图，压缩转 WebP，登记 license 台账 | `assets/img/` + `license.md` | **待团队**（占位图待替换） |
| D2-12 | 剩余 60 条按城市包干完成 | 80 条终稿 | **待团队** |
| D2-13 | 全量质检 + 入库导出（端侧包 + 服务端索引） | 两份产物 | **待数据齐备**（命令已就绪：`data:lint --final` + `data:build`） |

**出口**：80 条通过质检，license 齐全，端侧包 ≤55MB。

---

## D3 后端与检索

| # | 任务 | 产出 | 依赖 |
|---|---|---|---|
| D3-1 | `apps/server` 骨架：Fastify + pino + Zod + env 加载 + `/api/health` | 服务可启动 | **已完成** |
| D3-2 | provider 层：`EmbeddingProvider`（百炼） | `ai/embedding/` | **已完成**（packages/ai） |
| D3-3 | provider 层：`RerankProvider`（百炼） | `ai/rerank/` | **已完成**（packages/ai） |
| D3-4 | provider 层：`LlmProvider`（DeepSeek，流式） | `ai/llm/` | **已完成**（packages/ai） |
| D3-5 | 连通性与限额实测脚本 + 记录 | `docs/ai-providers.md` | **已完成** |
| D3-6 | 服务端数据导入：chunk 文本 + FTS5 索引 + 向量索引 + 图谱表 | `data/import.ts` | **已完成**（导入 5 条用时 4ms） |
| D3-7 | `/api/items`、`/api/items/:id`、`/api/items/:id/related` | 只读接口 | D3-6 |
| D3-8 | `/api/search` BM25 版（含维度过滤） | 关键词检索 | D3-6 |
| D3-9 | 查询理解：实体词典识别（5 城 / 6 时代 / 类型 / 别名） | `search/query-understanding.ts` | **已完成**（含过约束自动放宽） |
| D3-10 | `/api/search` 混合检索版：向量 + RRF + 过滤 | 语义检索 | **已完成**（T-1 已解决） |
| D3-11 | 接入 Rerank，形成完整检索链 | 检索链定稿 | **已完成** |
| D3-12 | 调用统计（token / 次数 / 耗时）落表 + `/api/stats/usage` | 成本可观测 | **已完成** |

**出口**：混合检索明显优于纯关键词；调用有统计。

---

## D4 收藏笔记与分布式同步

| # | 任务 | 产出 | 依赖 |
|---|---|---|---|
| D4-1 | 端侧个人数据表：收藏（遗址+文物统一）/ 笔记 / 标签 / 进度 | `model/schema.ets` | **已完成**（含 LWW 元数据与软删） |
| D4-2 | 收藏 / 笔记 / 标签 的 UI 与交互 | 详情页与我的档案页 | **已完成**（UI 自动化实测通过） |
| D4-3 | 学习进度计算（去重条目 / 总数，按时代分段） | `service/ProgressService.ets` | **已完成**（并入 PersonalDao） |
| D4-4 | `SyncAdapter` 接口定义 | `service/sync/types.ets` | **已完成** |
| D4-5 | `HarmonyDistributedKV` 实现（主路径） | `service/sync/distributed.ets` | **已完成**（本机自检 11/11 通过） |
| D4-6 | 服务端同步服务（WS + LWW + 变更日志 + 冲突日志） | `apps/server/src/sync/` | **已完成**（双设备协议验证 17/17） |
| D4-7 | `CloudSync` 端侧实现（兜底通道） | `service/sync/cloud.ets` | **已完成**（两模拟器实测通过） |
| D4-8 | `IdentityAdapter` + 配对码页面（openid 主 / 配对码兜底） | `service/identity/` | D4-4 |
| D4-9 | 同步中心页：进度（n/m + 方向）/ 冲突列表 / 手动同步 | `pages/SyncPage.ets` | **已完成**（并入我的档案页同步卡） |
| D4-10 | 备份恢复：导出 / 导入合并 / 云端快照 | 接口 + UI | D4-6 |
| D4-11 | 双端冲突联调（两端离线改同一条 → 按最新时间戳收敛） | 测试记录 | **部分完成**（协议层已验证 17/17；UI 层冲突展示待补验） |

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
