# Claude Code Responses Adapter

让 Claude Code 通过本机适配器使用 OpenAI-compatible `/v1/responses` API。

## 要求

- Node.js 20+
- Claude Code
- 上游 API Key

## 安装

```bash
cd ~/claude-responses-adapter && ./install.sh
```

首次安装会提示输入 API Key。重新安装时自动复用已有凭据，无需再次输入。

### macOS

默认创建并启动 LaunchAgent（无需指定 service mode）。

### Linux

默认 `auto`：优先 `systemd --user`，不可用时退回 `nohup`。明确指定：

```bash
./install.sh --service-mode nohup    # 无 root 权限时使用
```

如果服务器在登出时终止用户进程，需要管理员开启 linger：

```bash
sudo loginctl enable-linger "$USER"
```

## 启用适配器配置

```bash
cp ~/.claude/settings_az.json ~/.claude/settings.json
```

切回原始配置：

```bash
cp ~/.claude/settings_mt.json ~/.claude/settings.json
```

## 验证

```bash
curl --noproxy '*' http://127.0.0.1:47827/health
claude -p --max-turns 1 "Reply with exactly OK."
```

## 更新

```bash
cd ~/claude-responses-adapter && git pull && ./install.sh
```

## 自定义选项

```bash
./install.sh --model gpt-5.6-terra --upstream https://ca.memofun.net --port 47827 --proxy http://10.0.0.1:8080
```

## 日志

```bash
tail -50 ~/.claude/logs/responses-adapter.error.log
```

Linux systemd 额外可用：

```bash
journalctl --user -u net.memofun.claude-responses-adapter.service -n 50 --no-pager
```
