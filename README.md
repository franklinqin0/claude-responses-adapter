# Claude Code Responses Adapter

让 Claude Code 通过本机适配器使用 OpenAI-compatible `/v1/responses` API。

Claude Code 仍向本机发送 Anthropic `/v1/messages` 请求；适配器负责转换请求体、SSE 流式事件、工具调用和工具结果，再把请求发往上游 `/v1/responses`。

## 要求

- macOS
- Node.js 20 或更新版本
- Claude Code
- 上游 API Key

如果没有 Node.js：

```bash
brew install node
```

## 安装

```bash
git clone <你的仓库 URL>
cd claude-responses-adapter
chmod +x install.sh
./install.sh
```

安装器会隐藏输入 API Key，并执行以下操作：

- 将适配器安装到 `~/.claude/responses-adapter.mjs`
- 合并 `~/.claude/settings.json`，保留已有的其他配置
- 修改现有配置前生成带时间戳的备份
- 创建并启动 macOS LaunchAgent
- 将敏感配置文件权限设置为 `0600`
- 运行本地健康检查

默认配置：

- 上游：`https://ca.memofun.net`
- 模型：`gpt-5.6-sol`
- 本地监听：`127.0.0.1:47827`

可自定义：

```bash
./install.sh --model gpt-5.6-terra --upstream https://ca.memofun.net --port 47827
```

也可以使用环境变量，避免把 Key 写入 shell 历史：

```bash
read -r -s MEMOFUN_API_KEY
export MEMOFUN_API_KEY
./install.sh
unset MEMOFUN_API_KEY
```

## 验证

```bash
curl --noproxy '*' http://127.0.0.1:47827/health
claude -p --max-turns 1 "Reply with exactly OK."
```

检查后台服务：

```bash
launchctl print "gui/$(id -u)/net.memofun.claude-responses-adapter"
```

查看错误日志：

```bash
tail -50 ~/.claude/logs/responses-adapter.error.log
```

更新代码后重新安装：

```bash
git pull
./install.sh
```

## 安全说明

- 仓库内不包含 API Key。
- API Key 仅写入本机 `~/.claude/settings.json`。
- 本地适配器只监听 `127.0.0.1`。
- 使用自定义 API Key 时，Claude.ai connectors 会被 Claude Code 禁用，这是预期行为。
