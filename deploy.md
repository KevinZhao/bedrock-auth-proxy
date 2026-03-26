# 部署指南

在新机器上从零部署 Claude Code + Bedrock Auth Proxy，约 5 分钟。

## 前置条件

- macOS / Linux（支持 x86_64 和 arm64）
- 已安装 Claude Code（`npm install -g @anthropic-ai/claude-code`）
- 已获取 LLM Gateway 地址和认证 token

## 步骤一：克隆仓库

```bash
git clone https://github.com/KevinZhao/bedrock-auth-proxy.git ~/bedrock-auth-proxy
cd ~/bedrock-auth-proxy
```

## 步骤二：配置 settings.json

```bash
mkdir -p ~/.claude
cp settings.json.example ~/.claude/settings.json
```

编辑 `~/.claude/settings.json`，替换 auth token：

| 占位符 | 替换为 | 示例 |
|-------|--------|------|
| `your-auth-token` | 你的认证 token 值 | `a1b2c3d4e5f6789012345678abcdef90` |

## 步骤三：启动 Proxy 并运行 Claude Code

```bash
source ~/bedrock-auth-proxy/start.sh
claude
```

`source` 方式启动会同时：
1. 从 `~/.claude/settings.json` 读取环境变量（包括 `UPSTREAM_ENDPOINT` 等）
2. 自动下载对应平台的二进制文件（首次）
3. 启动 proxy 并等待就绪
4. 导出 `CLAUDE_CODE_USE_BEDROCK` 等变量到当前 shell

首次启动 Claude Code 时选择 **Bedrock** 认证即可。

## 自动启动 Proxy（推荐）

在 `~/.claude/settings.json` 中添加 SessionStart hook，每次打开 Claude Code 时自动启动 proxy：

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/bedrock-auth-proxy/start.sh",
            "timeout": 10,
            "statusMessage": "Starting bedrock-auth-proxy..."
          }
        ]
      }
    ]
  }
}
```

将上面的 `hooks` 块合并到你的 settings.json 中（与 `env`、`permissions` 同级）。

> **注意：** 此方式依赖公司内网访问 LLM Gateway。离开公司网络（如断开 VPN）后 Claude Code 将无法正常使用。

## 验证

在 Claude Code 中输入任意问题，能正常回复即部署成功。

如遇问题，检查 proxy 日志（设置 `DEBUG=1` 环境变量可开启详细日志）：

```bash
cat ~/bedrock-auth-proxy/proxy.log
```

日志中会显示完整的请求生命周期：
- `>>> POST /model/.../invoke` — 收到的请求
- `rewrite path: ... → ...` — URL 路径改写（去除 model ID）
- `target: https://...` — 实际转发的目标 URL
- `<<< 200 ... (xxxms)` — upstream 响应状态和耗时
- `upstream 4xx/5xx` — 错误响应及 body 内容

## 常见问题

### Proxy 启动报 "UPSTREAM_ENDPOINT is required"

`start.sh` 会自动从 `~/.claude/settings.json` 读取环境变量。确认 settings.json 中 `UPSTREAM_ENDPOINT` 已填写且文件格式正确。

### Claude Code 首次认证选 Bedrock 失败

确保：
1. Proxy 已启动（`source start.sh`，不是 `./start.sh`）
2. settings.json 中包含 `CLAUDE_CODE_USE_BEDROCK` 和 `CLAUDE_CODE_SKIP_BEDROCK_AUTH`

### 日志显示 "model xxx is not available"

Claude Code Bedrock 模式要求使用 Bedrock 格式的 model ID。检查 settings.json 中的 `ANTHROPIC_MODEL` 是否为 Bedrock 格式（如 `global.anthropic.claude-sonnet-4-6[1m]`），而不是 Anthropic API 格式（如 `claude-sonnet-4-6`）。

## 启停命令

```bash
# 启动（推荐 source 方式）
source ~/bedrock-auth-proxy/start.sh

# 停止
~/bedrock-auth-proxy/stop.sh

# 查看日志
tail -f ~/bedrock-auth-proxy/proxy.log

# 重启（更新二进制后）
~/bedrock-auth-proxy/stop.sh
rm -f ~/bedrock-auth-proxy/bedrock-auth-proxy
source ~/bedrock-auth-proxy/start.sh
```

## 工作原理

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
  LLM Gateway (如 Runway)
      | token 决定路由到哪个模型
      v
  AWS Bedrock
```
