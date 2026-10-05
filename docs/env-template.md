# 环境变量模板

> 复制为仓库根目录的 `.env` 并填入真实值。`.env` 已在 `.gitignore` 中，不会入库。
> 为什么放根目录：数据流水线（构建期）与服务端（运行期）用同一批 Key，放一处避免两套配置不同步。

## 创建方式

**推荐：用初始化脚本**（单行命令，不会像 heredoc 那样在粘贴时出问题）

```bash
cd <仓库根目录>
pnpm env:init -- --dashscope=<百炼Key> --deepseek=<DeepSeekKey>
```

脚本会写入 `.env` 并回显脱敏后的 Key 用于核对；已有 `.env` 时需加 `--force` 才覆盖。

**备选：手写文件**

```bash
cd <仓库根目录>
cat > .env <<'EOF'
DASHSCOPE_API_KEY=你的百炼Key
DEEPSEEK_API_KEY=你的DeepSeekKey

DASHSCOPE_BASE_URL=https://dashscope.aliyuncs.com
DEEPSEEK_BASE_URL=https://api.deepseek.com

EMBEDDING_MODEL=text-embedding-v4
EMBEDDING_DIM=1024
RERANK_MODEL=gte-rerank-v2
DEEPSEEK_MODEL=deepseek-chat
EOF
```

写完后用 `pnpm ai:check` 验证连通性。

## 变量说明

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `DASHSCOPE_API_KEY` | 是 | — | 阿里云百炼 API Key，用于嵌入与重排 |
| `DEEPSEEK_API_KEY` | 是 | — | DeepSeek API Key，用于问答生成与内容起草 |
| `DASHSCOPE_BASE_URL` | 否 | `https://dashscope.aliyuncs.com` | 百炼服务地址 |
| `DEEPSEEK_BASE_URL` | 否 | `https://api.deepseek.com` | DeepSeek 服务地址 |
| `EMBEDDING_MODEL` | 否 | `text-embedding-v4` | 嵌入模型，实测记录见 [ai-providers.md](./ai-providers.md) |
| `EMBEDDING_DIM` | 否 | `1024` | 嵌入维度，**一经选定不可随意改**（需重建索引） |
| `RERANK_MODEL` | 否 | `gte-rerank-v2` | 重排模型 |
| `DEEPSEEK_MODEL` | 否 | `deepseek-chat` | 生成模型 |

## 安全约定

- `.env` **不进仓库**（`.gitignore` 已覆盖）
- 密钥不进聊天记录、不进截图、**不进演示视频**
- 提交前的 pre-commit 钩子会扫描 `sk-` 开头的疑似密钥并阻止提交
- 队友首次使用前需各自创建 `.env`，**不要互相传文件**
