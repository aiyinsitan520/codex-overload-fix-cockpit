# Codex 满载修复 · cockpit-tools 版

> **这是一个衍生版（fork）。** 原始项目是
> [**NewBeeM4n/codex-overload-fix**](https://github.com/NewBeeM4n/codex-overload-fix)（MIT）。
> 故障定性、实测数据、「未出字前才重试」的安全规则、单文件中继的设计，**全部是他的工作**。
> 这个版本只补了「中继放在本地网关（cockpit-tools）后面」时才会暴露的那部分问题。
> 完整改动清单：[ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md)。
> 如果这个项目帮到你，请先去给上游仓库点 star。

一个本地重试中继，让 **「Selected model is at capacity. Please try a different model.」**
不再打断你干活 —— 专为 **Codex 已经走 cockpit-tools（或任何本地账号池网关）** 的
部署形态而做。

```
Codex  ──►  127.0.0.1:8788（中继）  ──►  127.0.0.1:8888（cockpit-tools）  ──►  上游
```

中继在这条链上只加一件事：**帮网关重试它自己重试不了的那次拒绝**。
账号轮换、会话亲和、额度池、图片生成仍然归 cockpit-tools，原样不动。

---

## 为什么需要这个衍生版

上游仓库假设中继直连 `chatgpt.com`。放在 cockpit-tools 后面，三处会出事：

| 现象 | 原因 | 本版处理 |
|---|---|---|
| 网关一挂，对话「思考」约 5 分钟才报错 | 连接类错误和 overload 共用 30 次 / 300 秒预算 | `--max-conn-attempts 3 --conn-budget 15`，几秒内失败 |
| 客户端不显示「满载」而是解析错误 | 放弃时返回 **HTTP 200** + JSON 体，却声明 `text/event-stream` | 改为 `503` + `Retry-After` + JSON 错误体 |
| 中继在跑，满载照样弹给你 | `response.output_item.added` 被判成「已提交」，但真实抓包是 **created → in_progress → output_item.added → overload**，此时一个字都没出 | 前置事件只算「暂缓」，只有真实内容才算提交 |
| 图片任务卡住 | `response.image_generation_call.*` 不在提交集合里 | 图片事件算提交 |
| 网关冷却期越重试越糟 | cockpit 整池冷却时微秒级返回 503，重试只会延长冷却 | 按延迟识别，`--cooling-wait` 强制间隔 |
| 中继悄悄失效，日志一片健康 | 网关 App 会把 `model_provider` 改回去 | `python tools/relayctl.py path` 一行看清 |
| `/v1/v1/responses` → 404 | `base_url` 本身已含 `/v1` | `--upstream` 自动剥掉尾部 `/v1` |

还有一件上游不可能预先知道的事：**并发三个 790 KB 请求在本机是常态**（有实测）。
按请求各自重试时，最坏会变成 27 次同时打网关。本版加了一个进程级的闸门。

`✶ Insight ─────────────────────────────────────`
上游 README 自己解释了为什么服务端排队会雪崩：客户端超时重试，重试流量把问题放大。
一个朴素的客户端重试层会在**更矮的一层**复制同一个雪崩：N 个客户端 × K 次尝试，
而且退避时间戳还差不多同步。`--retries-per-sec` 是对「重试起点」做令牌桶，
`--max-concurrent` 是对「在途尝试」做信号量——这样重试层不会变成它想吸收的那个过载。
`─────────────────────────────────────────────────`

---

## 快速开始（Windows + cockpit-tools）

```powershell
git clone <本仓库>
cd codex-overload-fix-cockpit
powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -Cockpit
```

安装脚本会：

1. 找 Python 3.9+（纯标准库，无依赖）；
2. 目标端口被占用就报警；直接指向 cockpit 自己的端口则拒绝安装；
3. 在 `%LOCALAPPDATA%\codex-overload-fix` 写隐藏启动器 + 看门狗，注册到
   `HKCU\...\Run`（不要管理员权限，无控制台窗口）；
4. **从你现有的 `[model_providers.codex_local_access]` 里拷出
   `experimental_bearer_token` 和 `http_headers`** 到新 provider —— 这两个是 cockpit
   识别调用方的凭据，漏了就全被拒；
5. 打印需要粘贴的配置块。

然后在 `%USERPROFILE%\.codex\config.toml` 中：

```toml
model_provider = "codex_local_access_retry"

[model_providers.codex_local_access_retry]
name = "Codex API Service (retry)"
base_url = "http://127.0.0.1:8788/v1"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
experimental_bearer_token = "..."      # 从 codex_local_access 拷
http_headers = { ... }                 # 从 codex_local_access 拷
stream_max_retries = 20
request_max_retries = 10
```

**完全退出并重启 Codex**（托盘图标 → Quit，不是关窗口）。

`experimental_realtime_ws_base_url` 保持指向 cockpit（`:8888`）——中继只处理 HTTP。

### 确认它真的在工作

```powershell
python tools\relayctl.py path      # model_provider 是不是 retry provider？
python tools\relayctl.py status    # 计数：请求 / 重试 / 放弃
python tools\relayctl.py quota     # cockpit 自己的账号池视图
python tools\relayctl.py probe     # 发一个最小请求，报告用了几次尝试
```

`path` 是最重要的那条。中继可以运行得完美无缺，而 `model_provider` 指向别处 ——
那它什么也没保护，而且日志看起来一切正常，因为根本没有流量。

### 不用 cockpit-tools 的话

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install.ps1           # 端口 8787
```

用 `config\config.example.toml`（中继 → `chatgpt.com`）。出口需要代理就加
`-Proxy http://127.0.0.1:7897`。

---

## 它到底做什么

**吞掉四种拒绝形态**，全部在内容到达客户端之前：

| 形态 | 出现在哪 |
|---|---|
| `{"type":"error", ..., "code":"server_is_overloaded"}` | HTTP **200** 的 SSE 流里（真实形态） |
| `response.failed` + `server_overloaded` | SSE 事件 |
| HTTP `503` / `502` / `504` / `500` / `429` | 状态行（cockpit 转出来的就是这个） |
| 微秒级 `503` 冷却短路 | 状态行，cockpit 特有 |

**提交后绝不重试。** 提交 = 以下任一首次出现：
`output_text.delta`、`reasoning_summary_text.delta`、`reasoning_text.delta`、
`output_item.done`、`completed`、`incomplete`，以及任何
`image_generation_call.partial_image / .completed`。
而 `response.created`、`in_progress`、`output_item.added`、`content_part.added`
只是**暂缓**——真实 overload 恰恰紧跟在这几个之后。

**绝不留下半截流。** 如果已经出字后才遇到 overload，直接断连接让客户端自己重试，
不在这里重试，所以输出不可能生成两遍。

**你停它就停。** 每 200 ms 轮询客户端 socket；取消或退出立即放弃重试，
退避 sleep 期间也一样。

**按失败类型用不同预算。**

| 失败 | 预算 | 结果 |
|---|---|---|
| 连接被拒 / 重置 | `--max-conn-attempts 3`，`--conn-budget 15s` | 几秒内 `503 upstream_unreachable` |
| in-band overload / 网关 503 | `--max-attempts 30`，`--total-budget 300s` | 重试，由全局令牌桶限速 |
| 整池冷却 | 同上，另有 `--cooling-wait 5s` 下限 | 重试，但绝不猛打 |
| 鉴权 / 非法请求 | 无 | 原样透传 —— 那是客户端该看到的答案 |

---

## 调参

默认值是按「一台机器 + cockpit-tools + 两个 Plus 账号」定的。

| 参数 | 默认 | 什么时候调大 | 什么时候调小 |
|---|---|---|---|
| `--max-attempts` | 30 | 大请求还在被放弃 | 想更保守 |
| `--total-budget` | 300 | 业务上确实会排队数分钟 | 不想等太久 |
| `--max-concurrent` | 4 | 同时跑很多 agent | 发现网关本身被打满 |
| `--retries-per-sec` | 2 | overload 窗口很短 | 出现持续 overload（这是防雪崩的主旋钮） |
| `--cooling-wait` | 5 | cockpit 冷却时间长 | 账号池恢复很快 |
| `--commit-deadline` | 120 | — | 想更严格限制首字延迟 |
| `--conn-budget` | 15 | 网关重启更慢 | — |

最有用的一组数字：`relayctl.py status` 里的 **`retries` 对 `giveups`**。
重试在涨、放弃为 0 = 中继在干活。放弃在涨 = 上游窗口比预算长，或者请求太大，
这两件中继修不了。

---

## 另一半：少发点

中继只是把拒绝藏起来，不创造容量。上游自己的数据（一晚 71 次请求）显示的是断崖：

| 请求体 | n | 平均尝试 | 最坏 |
|---|---|---|---|
| < 100 KB | 20 | 1.95 | 5 |
| 100–200 KB | 24 | 1.96 | 9 |
| 200–500 KB | 23 | 1.74 | 4 |
| **> 500 KB** | **4** | **6.75** | **9** |

本机经中继的实测：**531 KB** 和 **791 KB** 的单次请求都是一次成功 —— 所以断崖是概率性的，
不是硬阈值。但覆盖「平均值」正是重试预算要做的事。

免费杠杆，按效果排序：

1. **开新会话。** 桌面版每轮重发整个线程；长线程 `pre_compression_bytes ≈ 724,000`，
   新会话约 89 KB。
2. **删掉不用的技能和插件。** 72 个技能 = 每轮 20.4 KB 清单。
3. **压缩附图。** 带图任务第一轮就可能 700+ KB。
4. **精简记忆块**（每轮 12.8 KB，每轮都重发）。

`tools/capture_server.py` 可以量出你的客户端到底发了多少。

---

## 安全吗

- **不碰凭据**。用 Codex 原本就带的头转发，不存储、不记录、不外传。
  日志只记请求**体积**，不记 body 和 `Authorization`。
- **请求体字节级不变**，包括压缩体。
- **不绕配额**。只是把服务器已经拒绝过的请求再发一次 —— 和你手点重试一样，只是抢在报错之前。
- **纯本地**。`127.0.0.1` 上的一个 Python 进程，没有第三方服务器，没有共享账号池。
  从 `config.toml` 删一行就回到直连。
- **不可能重复生成**，因为提交后不重试。
- **关于账号风险**：任何改变请求时序的客户端都偏离了默认行为。
  想更保守就把 `--max-attempts` 降到 10。

它**修不了**：真额度耗尽、登录过期、网络不通、模型本身降智。这些原样透传。

---

## 已知限制

- 提供了 Windows 启动器；中继本体跨平台。
- 只处理 HTTP。WebSocket / realtime 不代理 —— 把
  `experimental_realtime_ws_base_url` 留给 cockpit。
- 全局闸门在进程内。两个端口各跑一个实例 = 两份独立预算，所以只跑一个。
- 预算按**轮次**算，不按会话。每一步工具调用都是服务器新拒绝的请求，各自重试是对的。
- 只在 Windows 11 + Python 3.10 上验证。`tests/run_tests.py` 哪都能跑。

---

## 目录结构

```
relay/relay.py             中继主体（单文件、纯标准库）
tools/relayctl.py          status / quota / probe / path
tools/capture_server.py    量出客户端实际发出的请求      （来自上游）
tools/analyze_log.py       汇总 relay.log                （来自上游）
scripts/install.ps1        隐藏启动器 + 看门狗 + 配置片段
scripts/uninstall.ps1      移除自启、结束进程
config/                    config.toml 示例（cockpit / 直连）
tests/run_tests.py         44 条断言，自带 mock 上游，无依赖
tests/mock_upstream.py     可编程的假上游
```

```powershell
python tests\run_tests.py          # 全部
python tests\run_tests.py --unit   # 只跑分类器
```

---

## 许可

MIT，见 [LICENSE](LICENSE) —— 上游版权声明原样保留，因为这堆代码大部分是他写的。
