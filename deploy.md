# 部署指南

3 步完成部署，无需 Go 环境，无需手动下载二进制。

## 1. 克隆仓库

```bash
git clone https://github.com/KevinZhao/bedrock-auth-proxy.git ~/bedrock-auth-proxy
cd ~/bedrock-auth-proxy
```

首次启动时 `start.sh` 会自动检测平台并下载对应的二进制文件到仓库目录。

## 2. 配置 Claude Code

复制配置模板到 `~/.claude/settings.json`，然后编辑替换占位符：

```bash
mkdir -p ~/.claude
cp settings.json.example ~/.claude/settings.json
vi ~/.claude/settings.json
```

| 占位符 | 替换为 |
|-------|--------|
| `https://your-gateway.example.com/api/bedrock_runtime` | 你的 LLM Gateway 地址 |
| `your-auth-token` | 认证 token 值 |

如需自动启动 proxy，取消 hooks 部分的注释并确认 `command` 路径指向 `~/bedrock-auth-proxy/start.sh`。

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
