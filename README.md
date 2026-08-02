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
- 将适配器配置写入 `~/.claude/settings_az.json`（备用文件），**不修改**正在使用的 `~/.claude/settings.json`
- 基于现有 `settings.json` 生成备用配置，保留已有的其他配置项
- 重新安装时安全复用已有本地适配器凭据，不显示 API Key
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

Linux 服务模式默认为 `auto`：优先使用 `systemd --user`，不可用时自动退回无需 root 的 `nohup` 进程。也可明确选择：

```bash
./install.sh --service-mode systemd
./install.sh --service-mode nohup
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

使用 systemd 时：

```bash
systemctl --user status net.memofun.claude-responses-adapter.service --no-pager
journalctl --user -u net.memofun.claude-responses-adapter.service -n 50 --no-pager
```

使用自动 `nohup` 回退时：

```bash
ps -p "$(cat ~/.claude/responses-adapter.pid)" -o pid,etime,command
tail -50 ~/.claude/logs/responses-adapter.error.log
```

`nohup` 不需要 sudo，但受服务器策略影响，可能在退出 SSH 或重启后停止。重新运行 `./install.sh --service-mode nohup` 即可启动。

部分无桌面的 Linux 服务器没有持久用户会话。只有管理员有权开启 linger：

```bash
sudo loginctl enable-linger "$USER"
```

如果你没有 sudo 权限，不要切换到 root；直接使用默认 `auto` 或明确使用 `nohup`：

```bash
./install.sh --service-mode nohup
```

若服务器在登出时强制终止所有用户进程，则需要管理员开启 linger，或使用该集群批准的任务守护方式（例如 Slurm、Supervisor、tmux）。

更新代码后重新安装：

```bash
git pull
./install.sh
```

如果现有 `settings.json`、`settings_mt.json` 或 `settings_az.json` 已指向本地适配器，更新安装时会自动复用已有凭据，不需要再次输入 Key。

安装完成后，备用配置位于 `~/.claude/settings_az.json`，原始配置可保存为 `~/.claude/settings_mt.json`。切换方式：

```bash
cp ~/.claude/settings_mt.json ~/.claude/settings.json   # 切回原始配置
cp ~/.claude/settings_az.json ~/.claude/settings.json   # 切到 Responses 适配器
```

## 安全说明

- 仓库内不包含 API Key。
- API Key 仅写入本机 `~/.claude/settings.json`。
- 本地适配器只监听 `127.0.0.1`。
- macOS LaunchAgent 和 Linux systemd unit 均不保存 API Key；适配器从 Claude Code 的本地请求转发认证头。
- 使用自定义 API Key 时，Claude.ai connectors 会被 Claude Code 禁用，这是预期行为。
