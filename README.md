# iceLLM

**Turn your Android phone into an OpenAI-compatible local AI server — one command.**

![license](https://img.shields.io/badge/license-MIT-blue.svg)
![platform](https://img.shields.io/badge/platform-Android%20(Termux)-3DDC84.svg)
![model](https://img.shields.io/badge/models-MiniCPM5%20%7C%20Qwen2.5-orange.svg)
[![中文](https://img.shields.io/badge/%E6%96%87%E6%A1%A3-%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-red.svg)](#中文)

```bash
curl -fsSL https://raw.githubusercontent.com/ice-wocker/iceLLM/main/ice-llm.sh | bash
```

> raw.githubusercontent.com blocked? Use the jsDelivr CDN mirror:
> ```bash
> curl -fsSL https://cdn.jsdelivr.net/gh/ice-wocker/iceLLM@main/ice-llm.sh | bash
> ```

After install you get a local LLM on your LAN:

- **WebUI** — chat in your phone's browser
- **OpenAI API** — `http://<phone-ip>:8080/v1/chat/completions`, works with any OpenAI client (Cherry Studio, Open WebUI, your own code) — just change `base_url`
- **Fully offline** — no API key, no cloud, no data leaves your device

## Why

Your phone has 4–8 CPU cores and 8–16 GB of RAM, idle 99% of the time. Running a 1B-class local model needs only a slice of that.

iceLLM automates the boring parts:

1. Installs `llama-cpp` from the official Termux repo (no compilation)
2. Downloads models from **ModelScope** (fast in mainland China, resumable)
3. Boots `llama-server` with an OpenAI-compatible endpoint + WebUI
4. Prints your LAN URLs so any device can connect

No root, no Termux add-on plugins, no flashing.

## Quick Start

### 1. Install Termux
Get it from F-Droid or GitHub Releases (the Play Store build is outdated).

### 2. One-line install
Run inside Termux (swap in the jsDelivr command above if raw is blocked):
```bash
curl -fsSL https://raw.githubusercontent.com/ice-wocker/iceLLM/main/ice-llm.sh | bash
```
The script installs dependencies → downloads the default model (MiniCPM5-1B, ~688 MB) → starts the server.

### 3. Use it
The terminal prints:
```
  WebUI:      http://192.168.x.x:8080
  OpenAI API: http://192.168.x.x:8080/v1/chat/completions
```
Open the WebUI from any browser on your LAN and start chatting.

## Commands

```
ice-llm                 # install & start (default model)
ice-llm start|stop      # start / stop
ice-llm restart|status  # restart / status
ice-llm models          # list downloaded + downloadable models
ice-llm model qwen15    # download & switch model
ice-llm model <gguf-URL>   # download any GGUF
ice-llm url             # print access URLs again
ice-llm test            # smoke test: real inference request (1-3 min on 1B)
ice-llm logs            # show server log
ice-llm autostart on    # auto-start when Termux opens
```

The script copies itself to `~/ice-llm/ice-llm.sh`; alias it or call the full path.

## Models

| Key | Model | Size | Notes |
|---|---|---|---|
| `minicpm5` | MiniCPM5-1B-Q4_K_M | 688MB | Default. Strong in Chinese, thinking mode (`reasoning_content`), tool calling |
| `qwen15` | Qwen2.5-1.5B-Instruct-Q4_K_M | ~950MB | Solid instruction following, stable long text |

Any GGUF works too: `ice-llm model https://.../xxx.gguf`

### Real-world speed

Speed depends on your SoC and memory bandwidth:

| Device class | 1B model | 1.5B model |
|---|---|---|
| Mid-range (Dimensity 6020, etc.) | ~0.3–1 tok/s | slow |
| Flagship (8 Gen / Dimensity 9000+) | ~3–8 tok/s | ~1–3 tok/s |

**The pitch is "free + private + always available", not raw speed.** Short Q&A, summarizing, rewriting, code completion all feel fine; for long-form generation use a flagship phone or a smaller model.

## Use it from your code

```python
from openai import OpenAI
client = OpenAI(base_url="http://192.168.1.53:8080/v1", api_key="none")
r = client.chat.completions.create(
    model="local",
    messages=[{"role": "user", "content": "Explain GGUF in one sentence"}],
)
print(r.choices[0].message.content)
```

## FAQ

**Q: Model download got interrupted?**
Re-run `ice-llm model <key>` — `curl -C -` resumes where it left off.

**Q: Port 8080 is taken?**
`ICE_LLM_PORT=9000 ice-llm start`

**Q: The server dies after a while?**
Android killed Termux. Enable "Acquire wakelock" in Termux settings, and run `ice-llm autostart on`.

**Q: MiniCPM5 replies are empty / very slow?**
It's a *thinking* model — it emits a long `reasoning_content` pass before the answer. Add `"reasoning_effort":"none"` to the request to disable thinking (measured: 31s vs 74s). `ice-llm test` already sends that flag.

**Q: Access from outside the LAN?**
By default it listens on the LAN only. For the internet use frp / Tailscale — and definitely add `--api-key`.

**Q: Will it cook my battery?**
Inference pins the CPU: expect heat and drain. Run `ice-llm stop` when done.

## How it works

```
Termux (Android)
└── llama-cpp/llama-server     # OpenAI-compatible HTTP server
    ├── model: GGUF (Q4_K_M)    # downloaded from ModelScope
    ├── WebUI                   # built-in, at /
    └── /v1/chat/completions    # standard OpenAI protocol
```

- Single-file script, no Python / Node dependencies
- Models cached in `~/ice-llm/models/`, existing `.gguf` in `$HOME` are reused
- Log: `~/ice-llm/ice-llm.log`

## License

[MIT](LICENSE)

---

# 中文

**一行命令，把你的安卓手机变成 OpenAI 兼容的本地 AI 服务器。**

```bash
curl -fsSL https://raw.githubusercontent.com/ice-wocker/iceLLM/main/ice-llm.sh | bash
```

> 🇨🇳 raw 域名不通？用 jsDelivr CDN 版：
> ```bash
> curl -fsSL https://cdn.jsdelivr.net/gh/ice-wocker/iceLLM@main/ice-llm.sh | bash
> ```

装完就有一个局域网里可用的本地 LLM：

- **WebUI** — 手机浏览器直接聊
- **OpenAI API** — `http://手机IP:8080/v1/chat/completions`，任何 OpenAI 客户端（Cherry Studio / Open WebUI / 你的代码）改个 `base_url` 就能接
- **完全离线** — 数据不出门，不用 API key，不花一分钱

## 为什么做这个

你的手机有 4~8 核 CPU + 8~16GB 内存，闲置 99% 的时间。跑一个 1B 级别的本地模型，只需要其中一小部分。

iceLLM 做的事：

1. 自动装 `llama-cpp`（Termux 官方源，无编译）
2. 从 **ModelScope（国内直连）** 下模型，支持断点续传
3. 起 `llama-server`，暴露 OpenAI 兼容接口 + WebUI
4. 打印局域网地址，电脑/平板/别的手机都能连

不 root、不装 Termux 插件、不刷机。

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
局域网里任意浏览器打开 WebUI 就能聊。

## 命令一览

```
ice-llm                 # 安装并启动（默认模型）
ice-llm start|stop      # 启停
ice-llm restart|status  # 重启 / 状态
ice-llm models          # 已下载 + 可下载的模型
ice-llm model qwen15    # 下载并切换模型
ice-llm model <任意gguf URL>   # 下任意模型
ice-llm url             # 重新打印访问地址
ice-llm test            # 自检: 发一条真实推理请求 (1B 模型可能要 1-3 分钟)
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
Termux 被系统杀了。Termux 设置里开「Acquire wakelock」，或 `ice-llm autostart on`。

**Q: MiniCPM5 回复是空的/特别慢？**
它是思考模型，默认先生成一大段 `reasoning_content` 再给正文。请求里加 `"reasoning_effort":"none"` 可关掉思考（实测 31s vs 74s，速度翻倍）。`ice-llm test` 已内置这个参数。

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

---

Made with ❄ on Android — [ice-wocker](https://github.com/ice-wocker)
