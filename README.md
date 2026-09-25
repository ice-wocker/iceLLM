# iceLLM

**一行命令，把你的安卓手机变成 OpenAI 兼容的本地 AI 服务器。**

![license](https://img.shields.io/badge/license-MIT-blue.svg)
![platform](https://img.shields.io/badge/platform-Android%20(Termux)-3DDC84.svg)
![python-free](https://img.shields.io/badge/deps-零依赖-ff69b4.svg)

```bash
curl -fsSL https://raw.githubusercontent.com/ice-wocker/iceLLM/main/ice-llm.sh | bash
```

> 🇨🇳 raw 域名不通？用 jsDelivr CDN 版：
> ```bash
> curl -fsSL https://cdn.jsdelivr.net/gh/ice-wocker/iceLLM@main/ice-llm.sh | bash
> ```

装完就有一个局域网里可用的本地 LLM：
- **WebUI** — 手机浏览器直接聊
- **OpenAI API** — `http://手机IP:8080/v1/chat/completions`，任何 OpenAI 客户端（Cherry Studio / Open WebUI / 你的代码）改个 base_url 就能接
- **完全离线** — 数据不出门，不用 API key，不用花一分钱

## 为什么做这个

你的手机有 4~8 核 CPU + 8~16GB 内存，闲置 99% 的时间。
而跑一个 1B 级别的本地模型，只需要其中一小部分。

iceLLM 做的事：
1. 自动装 `llama-cpp`（Termux 官方源，无编译）
2. 从 **ModelScope（国内直连）** 下模型，支持断点续传
3. 起 `llama-server`，暴露 OpenAI 兼容接口 + WebUI
4. 打印局域网地址，电脑/平板/别的手机都能连

不装 Termux 插件、不 root、不刷机。

## 快速开始

### 1. 安装 Termux
F-Droid 或 GitHub Releases 下载（Play Store 版已停更，别用）。

### 2. 一行安装
在 Termux 里执行（raw 不通就换上面 jsDelivr 版）：
```bash
curl -fsSL https://raw.githubusercontent.com/ice-wocker/iceLLM/main/ice-llm.sh | bash
```
脚本会自动：装依赖 → 下载默认模型（MiniCPM5-1B，约 688MB）→ 启动服务。

### 3. 用上它
终端会直接打印：
```
  WebUI:      http://192.168.x.x:8080
  OpenAI API: http://192.168.x.x:8080/v1/chat/completions
```
电脑浏览器打开 WebUI 就能聊。

## 命令一览

```
ice-llm                 # 安装并启动（默认模型）
ice-llm start|stop      # 启停
ice-llm restart|status  # 重启 / 状态
ice-llm models          # 已下载 + 可下载的模型
ice-llm model qwen15    # 下载并切换模型
ice-llm model <任意gguf URL>   # 下任意模型
ice-llm url             # 重新打印访问地址
ice-llm logs            # 看服务端日志
ice-llm autostart on    # Termux 开机自启
```

脚本会自动拷贝到 `~/ice-llm/ice-llm.sh`，加个 alias 或用全路径都行。

## 模型

| 名称 | 模型 | 大小 | 说明 |
|---|---|---|---|
| `minicpm5` | MiniCPM5-1B-Q4_K_M | 688MB | 默认。中文强，支持思考模式（`reasoning_content`），工具调用 |
| `qwen15` | Qwen2.5-1.5B-Instruct-Q4_K_M | ~950MB | 指令遵循好，长文本稳 |

也支持任意 GGUF：`ice-llm model https://.../xxx.gguf`

### 速度参考（真机实测）

速度取决于你的手机芯片和内存带宽，以下为大致量级：

| 设备档位 | 1B 模型 | 1.5B 模型 |
|---|---|---|
| 中端 (Dimensity 6020 等) | ~0.3-1 tok/s | 慢 |
| 旗舰 (8 Gen 系 / 天玑 9000+) | ~3-8 tok/s | ~1-3 tok/s |

**定位是"免费 + 私有 + 随时可用"**，不是拼速度。短问答、摘要、改写、代码补全很合适；要长文生成请上旗舰机或换更小的模型。

## 接你自己的代码

```python
from openai import OpenAI
client = OpenAI(base_url="http://192.168.1.53:8080/v1", api_key="none")
r = client.chat.completions.create(
    model="local",
    messages=[{"role": "user", "content": "用一句话解释什么是 GGUF"}],
)
print(r.choices[0].message.content)
```

## 常见问题

**Q: 下载模型中途断了？**
重跑 `ice-llm model <名称>` 即可，`curl -C -` 断点续传。

**Q: 端口 8080 被占了？**
`ICE_LLM_PORT=9000 ice-llm start`

**Q: 后台跑一会儿就没了？**
Termux 被系统杀了。Termux 设置里开「Acquire wakelock」，或 `ice-llm autostart on` + 装 termux-api。

**Q: 局域网以外能访问吗？**
默认只监听局域网。要公网访问请自己套 frp / Tailscale，并务必加 `--api-key`。

**Q: 会伤电池吗？**
推理时 CPU 满载，会发热耗电。聊完 `ice-llm stop`。

## 工作原理

```
Termux (安卓)
└── llama-cpp/llama-server     # OpenAI 兼容 HTTP 服务
    ├── 模型: GGUF (Q4_K_M)     # ModelScope 国内直连
    ├── WebUI                   # 内置, / 路径
    └── /v1/chat/completions    # 标准 OpenAI 协议
```

- 单文件脚本，无 Python / Node 依赖
- 模型缓存在 `~/ice-llm/models/`，`$HOME` 下已有的 `.gguf` 直接复用
- 日志：`~/ice-llm/ice-llm.log`

## License

[MIT](LICENSE)

---
made with ❄ on Android — [ice-wocker](https://github.com/ice-wocker)
