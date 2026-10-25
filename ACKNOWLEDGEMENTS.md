# Acknowledgements and provenance / 来源与致谢

## Upstream

This project is a **derivative work** of:

> **codex-overload-fix** — https://github.com/NewBeeM4n/codex-overload-fix
> Author: **NewBeeM4n**
> License: MIT (see `LICENSE`)
> Upstream commit this fork was taken from:
> `57bb7b23594eb1d20aaee1fac9e70d91ed4fc373`
> ("Limitations: state plainly that the shim does not fix a degraded model",
> 2026-10-24)

The original idea, the diagnosis that the capacity error arrives as an
`error` event inside an HTTP 200 SSE stream, the size-vs-attempts measurement,
the "retry only before commit" safety rule, and the single-file stdlib relay
design are all **his work**. Nothing here would exist without it.

If this helps you, star the upstream repo first: it is where the diagnosis
lives and where the next person's agent will look.

## What this fork changes

This fork was written for one specific environment: **Codex behind
cockpit-tools**. Everything below is a response to a failure mode observed
in that layout, not a general criticism of the original.

| # | Change | Why |
|---|---|---|
| 1 | **Separate budgets per failure class** (`--max-conn-attempts`, `--conn-budget`) | The original gives `ConnectionRefusedError` the same 30-attempt / 300 s budget as overload. When the local gateway is not running, the app appears to "think" for up to five minutes before failing — strictly worse than failing instantly. |
| 2 | **Give-up returns `503` + `Retry-After` + JSON** | The original returns HTTP 200 with a JSON body while declaring `Content-Type: text/event-stream`. A client that parses SSE sees malformed data; there is no signal that this was a failure. |
| 3 | **Image-generation events count as committed** | `response.image_generation_call.*` was missing from the commit set, so an image task could be held behind `--commit-deadline` (120 s) waiting for an overload verdict it would never get. |
| 4 | **Bare `error` events are triaged** | The original commits on *any* non-overload `error` event. `rate_limit_exceeded` / `incomplete_upstream_stream` are worth another attempt; `invalid_api_key` is not. Now split by code. |
| 5 | **A process-wide gate** (`--max-concurrent`, `--retries-per-sec`) | The original retries per request. Three concurrent 790 KB requests (a real pattern) can become 27 simultaneous punts at the upstream. The gate caps in-flight attempts and the global retry rate, which is the same reasoning the upstream README itself gives for why server-side queues stampede. |
| 6 | **`response.output_item.added` is a hold, not a commit** | Real captured traffic shows `response.created` → `response.in_progress` → `output_item.added` → **overload**, with no text yet. Committing on `output_item.added` means the overload that follows is too late to retry. |
| 7 | **cockpit pool-cooling detection** | cockpit-tools answers in microseconds when its whole account pool is in cooldown. That is a 503 that looks like a real upstream 503. The relay recognises it by latency and waits `--cooling-wait` instead of hammering (which extends the cooldown). |
| 8 | **`--upstream` accepts a `/v1` suffix** | `base_url` already carries `/v1`, so an upstream written as `http://127.0.0.1:8888/v1` used to produce `/v1/v1/responses` → 404. Now normalised, with a printed notice. |
| 9 | **`GET /__relay/health`** | The original's only observability is a log file. A JSON counter surface makes "is the relay in the path, and is it absorbing anything?" a one-liner (see `tools/relayctl.py`). |
| 10 | **Sleeping is interruptible** | The original `time.sleep()`s through its backoff, so a cancelled turn keeps retrying for the full delay. Now polled in 200 ms slices against the client socket. |
| 11 | **`tools/relayctl.py`** | `path` answers the question that actually matters — *is the relay in the traffic path at all?* A running relay with a reverted `model_provider` protects nothing, which is exactly what had happened here. |
| 12 | **Non-streaming answers are not mistaken for streams** | A `stream: false` call (and `relayctl.py probe`) comes back as `application/json`. The original only knew how to read SSE, so a complete JSON answer looked like "stream ended early" — a retryable condition — and it retried until the client disconnected. Now the content type is checked first; a 200 JSON body is passed through verbatim, a JSON body whose `error` is an overload is retried. |
| 13 | **Test suite** (`tests/run_tests.py`, 44 assertions) | Mock upstream + relay, covering absorption, the no-duplicate-output boundary, image commits, non-streaming pass-through and JSON overload, cooling spacing, give-up shape, dead-upstream fast fail, and the `/v1` normalisation. |

## What was deliberately kept identical

- Byte-transparent proxying of request bodies (including zstd) and auth headers.
- The **never retry after content is committed** rule — including the
  mid-stream "drop the connection so the client retries" behaviour.
- The client-gone check (`select` + `MSG_PEEK`).
- The one-line rollback story.
- MIT licensing and the "no account sharing, no quota bypass, no protocol
  reverse-engineering" position.

## Naming

The repository name and the "cockpit" qualifier exist to distinguish this fork
from upstream, not to claim it as a separate product. If the upstream author
prefers a different name, or wants any of these changes folded in, both are
fine — open an issue upstream.

中文摘要：本项目是 [NewBeeM4n/codex-overload-fix](https://github.com/NewBeeM4n/codex-overload-fix)
（MIT）的衍生版，针对「Codex 经 cockpit-tools 网关」这一部署形态做了 13 处改进。
原始诊断、体积-重试相关性、单文件中继设计全部来自原作者。如果你觉得有用，
请先去给上游点 star。
