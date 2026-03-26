# Bedrock Auth Proxy

本地轻量代理，解决 Claude Code 无法直接连接自定义 LLM Gateway（如 Runway）的问题。

## 为什么需要这个 Proxy

Claude Code 连接后端有两种模式，但都无法直连使用自定义 header 认证的 Bedrock 网关：

| CC 模式 | 请求格式 | 自定义 Auth Header | 结论 |
|---------|---------|-------------------|------|
| Anthropic API | `/v1/messages` | 支持 | 网关只接受 Bedrock 格式，格式不匹配 |
| Bedrock | `/model/xxx/invoke` | 不支持（AWS SDK 强制 SigV4） | 无法传递网关认证 |

**两种模式各缺一半** — 一个格式对但没法加自定义 header，一个能加 header 但格式不对。

本 Proxy 作为桥梁，解决这个问题：

```
Claude Code (Bedrock 模式)
      |
      | POST /model/claude-opus-4-6/invoke
      v
  bedrock-auth-proxy (127.0.0.1:8888)
      | 1. 去除 URL 中的 model ID: /model/invoke
      | 2. 丢弃 SigV4 签名（Authorization + X-Amz-* headers）
      | 3. 注入自定义认证 header（如 token: xxx）
      v
  LLM Gateway (如 Runway) → Bedrock
```

Proxy 做的事情非常简单：**接收请求 → 去除 model ID → 注入认证 header → 转发到网关**。不修改请求体，不做协议转换。

## 快速开始

> 详细步骤见 [deploy.md](deploy.md)

```bash
# 1. 克隆仓库
git clone https://github.com/KevinZhao/bedrock-auth-proxy.git ~/bedrock-auth-proxy
cd ~/bedrock-auth-proxy

# 2. 复制配置模板并编辑（替换 auth token）
mkdir -p ~/.claude
cp settings.json.example ~/.claude/settings.json
vi ~/.claude/settings.json

# 3. 启动 proxy 并运行 Claude Code
source ./start.sh
claude
```

## 配置说明

完整配置参考 [settings.json.example](settings.json.example)，需替换以下值：

| 占位符 | 替换为 |
|-------|--------|
| `your-auth-token` | 认证 token 值 |

所有环境变量：

| 环境变量 | 必填 | 说明 |
|---------|------|------|
| `UPSTREAM_ENDPOINT` | 是 | LLM Gateway 的 Bedrock API 地址 |
| `AUTH_HEADER_NAME` | 是 | 认证 header 名称（如 `token`） |
| `AUTH_HEADER_VALUE` | 是 | 认证 header 值 |
| `PROXY_PORT` | 否 | 监听端口，默认 `8888` |
| `LISTEN_HOST` | 否 | 监听地址，默认 `127.0.0.1` |
| `DEBUG` | 否 | 设为 `1` 开启详细调试日志 |

> 详细部署步骤、验证和排错见 [deploy.md](deploy.md)

## 手动启停

```bash
# 启动
source ./start.sh

# 停止
./stop.sh
```

## 从源码构建

```bash
go build -ldflags="-s -w" -o bedrock-auth-proxy .
```
