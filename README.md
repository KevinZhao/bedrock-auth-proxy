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
      | Bedrock 格式请求（SigV4 签名被 proxy 丢弃）
      v
  bedrock-auth-proxy (127.0.0.1:8888)
      |
      | Bedrock 格式请求 + 自定义 Auth Header
      v
  LLM Gateway (如 Runway) → Bedrock
```

Proxy 做的事情非常简单：**接收请求 → 注入认证 header → 转发到网关**。不修改请求体，不做协议转换，159 行 Go 代码，约 5.6MB 二进制。

## 安装

从 [Releases](https://github.com/KevinZhao/bedrock-auth-proxy/releases) 下载对应平台的二进制文件：

```bash
# Linux x86_64
curl -Lo bedrock-auth-proxy https://github.com/KevinZhao/bedrock-auth-proxy/releases/latest/download/bedrock-auth-proxy-linux-amd64

# Linux ARM64
curl -Lo bedrock-auth-proxy https://github.com/KevinZhao/bedrock-auth-proxy/releases/latest/download/bedrock-auth-proxy-linux-arm64

# macOS Apple Silicon
curl -Lo bedrock-auth-proxy https://github.com/KevinZhao/bedrock-auth-proxy/releases/latest/download/bedrock-auth-proxy-darwin-arm64

# macOS Intel
curl -Lo bedrock-auth-proxy https://github.com/KevinZhao/bedrock-auth-proxy/releases/latest/download/bedrock-auth-proxy-darwin-amd64

# Windows
curl -Lo bedrock-auth-proxy.exe https://github.com/KevinZhao/bedrock-auth-proxy/releases/latest/download/bedrock-auth-proxy-windows-amd64.exe

chmod +x bedrock-auth-proxy
```

## 配置

### 第 1 步：配置 `~/.claude/settings.json`

将 proxy 二进制和 `start.sh` 放在同一目录（如 `~/bedrock-auth-proxy/`），编辑 `~/.claude/settings.json`，一站式完成 Claude Code 和 Proxy 的配置：

```jsonc
{
  "env": {
    // Claude Code 配置
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "ANTHROPIC_BEDROCK_BASE_URL": "http://127.0.0.1:8888",
    "CLAUDE_CODE_SKIP_BEDROCK_AUTH": "1",
    "AWS_REGION": "us-east-1",
    "ANTHROPIC_MODEL": "global.anthropic.claude-opus-4-6-v1[1m]",

    // Proxy 配置（start.sh 会继承这些环境变量）
    "UPSTREAM_ENDPOINT": "https://your-gateway.example.com/api/bedrock_runtime",
    "AUTH_HEADER_NAME": "token",
    "AUTH_HEADER_VALUE": "your-auth-token"
  },
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/bedrock-auth-proxy/start.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

| 环境变量 | 必填 | 说明 |
|---------|------|------|
| `UPSTREAM_ENDPOINT` | 是 | LLM Gateway 的 Bedrock API 地址 |
| `AUTH_HEADER_NAME` | 是 | 认证 header 名称（如 `token`） |
| `AUTH_HEADER_VALUE` | 是 | 认证 header 值 |
| `PROXY_PORT` | 否 | 监听端口，默认 `8888` |
| `LISTEN_HOST` | 否 | 监听地址，默认 `127.0.0.1` |

配置完成后，每次启动 `claude` 会通过 `SessionStart` hook 自动拉起 proxy，无需手动操作。

### 第 2 步：验证

```bash
claude
```

启动后 proxy 会自动运行，日志中可看到 `Bedrock Auth Proxy on 127.0.0.1:8888`。

## 手动启停

```bash
# 启动
./start.sh

# 停止
./stop.sh
```

## 从源码构建

```bash
go build -ldflags="-s -w" -o bedrock-auth-proxy .
```
