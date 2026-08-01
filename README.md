# Claude Code Responses Adapter

让 Claude Code 通过本机适配器使用 OpenAI-compatible `/v1/responses` API。

Claude Code 仍向本机发送 Anthropic `/v1/messages` 请求；适配器负责转换请求体、SSE 流式事件、工具调用和工具结果，再把请求发往上游 `/v1/responses`。

## 支持的平台与要求

- macOS（LaunchAgent）
- Linux（`systemd --user`）
- Node.js 20 或更新版本
- Claude Code
- 上游 API Key

确认 Node.js 版本：

```bash
node --version
```

macOS 可通过 Homebrew 安装：

```bash
brew install node
```

Linux 请使用发行版包管理器、NodeSource 或 nvm 安装 Node.js 20+。如果使用 nvm，安装器会把当前 Node 的绝对路径写入 systemd unit。

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
- macOS：创建并启动 LaunchAgent
- Linux：创建并启用 `systemd --user` 服务
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

### macOS 服务管理

```bash
launchctl print "gui/$(id -u)/net.memofun.claude-responses-adapter"
```

查看错误日志：

```bash
tail -50 ~/.claude/logs/responses-adapter.error.log
```

### Linux 服务管理

```bash
systemctl --user status net.memofun.claude-responses-adapter.service --no-pager
journalctl --user -u net.memofun.claude-responses-adapter.service -n 50 --no-pager
```

部分无桌面的 Linux 服务器没有持久用户会话。如果安装器提示无法连接用户级 systemd，执行一次：

```bash
sudo loginctl enable-linger "$USER"
```

然后重新登录，或重新执行：

```bash
systemctl --user daemon-reload
./install.sh
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
- macOS LaunchAgent 和 Linux systemd unit 均不保存 API Key；适配器从 Claude Code 的本地请求转发认证头。
- 使用自定义 API Key 时，Claude.ai connectors 会被 Claude Code 禁用，这是预期行为。
