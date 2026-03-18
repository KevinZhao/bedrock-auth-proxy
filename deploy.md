# 部署指南

3 步完成部署，无需 Go 环境，无需手动下载二进制。

## 1. 下载脚本

```bash
mkdir -p ~/bedrock-auth-proxy && cd ~/bedrock-auth-proxy
curl -fSLO https://raw.githubusercontent.com/KevinZhao/bedrock-auth-proxy/main/start.sh
curl -fSLO https://raw.githubusercontent.com/KevinZhao/bedrock-auth-proxy/main/stop.sh
chmod +x start.sh stop.sh
```

首次启动时 `start.sh` 会自动检测平台并下载对应的二进制文件到当前目录。

## 2. 配置 Claude Code

将配置模板下载到 `~/.claude/settings.json`，然后替换以下 3 个值：

```bash
mkdir -p ~/.claude
curl -fSL https://raw.githubusercontent.com/KevinZhao/bedrock-auth-proxy/main/settings.json.example \
  -o ~/.claude/settings.json
```

| 占位符 | 替换为 |
|-------|--------|
| `https://your-gateway.example.com/api/bedrock_runtime` | 你的 LLM Gateway 地址 |
| `token` | 认证 header 名称 |
| `your-auth-token` | 认证 header 值 |

快速复制：

```bash
# 然后编辑 ~/.claude/settings.json 替换占位符
vi ~/.claude/settings.json
```

如需自动启动 proxy，编辑 `~/.claude/settings.json`，取消 hooks 部分的注释并确认 `command` 路径正确。

## 3. 启动

```bash
claude
```

如果配置了 hooks，proxy 会随 Claude Code 自动启动。否则手动启动：

```bash
~/bedrock-auth-proxy/start.sh
```

## 验证

在 Claude Code 中输入任意问题，能正常回复即部署成功。

如遇问题，检查日志：

```bash
cat ~/bedrock-auth-proxy/proxy.log
```

## 停止 Proxy

```bash
~/bedrock-auth-proxy/stop.sh
```
