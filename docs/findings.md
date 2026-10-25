# Findings: the Codex "at capacity" error

> Original diagnosis, from [NewBeeM4n/codex-overload-fix](https://github.com/NewBeeM4n/codex-overload-fix) (MIT).
> Ports (8787) and provider names (`openai-retry`) in this document are the original
> layout. This fork defaults to 8788 / `codex_local_access_retry` behind cockpit-tools —
> see `docs/cockpit-notes.md`.

### A likely contributing factor: request size

Not a fix, but I've been instrumenting this for a few weeks and the data points somewhere specific.

**1. The error is not a 5xx.**

`server_is_overloaded` arrives as a bare `error` event *inside an HTTP 200* SSE stream:

```json
{"type":"error","sequence_number":3,
 "error":{"type":"service_unavailable_error",
          "code":"server_is_overloaded",
          "message":"Our servers are currently overloaded. Please try again later."}}
```

So no layer that retries on status codes ever sees it — the client reads the stream, then decides it failed. Response headers on the same call showed `x-codex-plan-type: plus` and an `x-codex-primary-used-percent` far below any cap, so quota wasn't the constraint.

**2. Attempts needed tracks request body size.**

Across 71 `/responses` calls through the shim in one evening on one account, the effect is not a gradient — it's a cliff:

| request body | n | attempts needed (mean) | worst |
|---|---|---|---|
| < 100 KB | 20 | 1.95 | 5 |
| 100–200 KB | 24 | 1.96 | 9 |
| 200–500 KB | 23 | 1.74 | 4 |
| **> 500 KB** | **4** | **6.75** | **9** |

Below ~500 KB the buckets are indistinguishable. Above it the mean jumps to 6.8. The four large bodies were all 768–799 KB and needed 7, 8, and 9 attempts (the fourth needed 3). No sample landed between 430 KB and 768 KB, so the exact threshold isn't pinned down. None were dropped — the shim absorbed 82 retries in total.

Two things worth flagging:
- The worst case coincided with **three ~770 KB requests issued in the same second**, so concurrency compounds it. That fits a per-minute admission window better than per-request randomness.
- Earlier, smaller runs also showed a model split inside the same windows (`gpt-5.6-terra` 8/8 vs `gpt-6.1-sol` 5/8, n=8 each) — directional only, not conclusive.

**3. Two things reduced it here.**

(a) **Larger client retry budget via a local retry shim.** `openai` is a reserved provider id, so it can't be overridden — but a custom provider can point at localhost:

```toml
model_provider = "openai-retry"

[model_providers.openai-retry]
base_url = "http://127.0.0.1:8787"
wire_api = "responses"
requires_openai_auth = true
stream_max_retries = 20
request_max_retries = 10
```

The shim forwards requests byte-for-byte and only retries when the overload event arrives **before any output token** is emitted. Once `response.output_text.delta` has been seen it passes the stream straight through, so nothing is generated twice. It also peeks the client socket and abandons retries if the turn was cancelled.

(b) **Smaller requests.** A fresh desktop conversation body is ~89 KB:

| part | size |
|---|---|
| `additional_tools` | 27.6 KB |
| base instructions | 17.7 KB |
| skill manifest (72 skills) | 20.4 KB |
| memory block | 12.8 KB |

Removing non-native skills and plugins got it to 71 KB (−20%). The larger effect was **starting a new conversation**: the app's own log reported `pre_compression_bytes ≈ 724,000` on a long-running thread vs 89 KB on a fresh one.

**4. What made no difference here.**

Five different egress networks (30/30 requests succeeded; rejection rate unchanged), switching models inside a bad window, system timezone, `service_tier`, restarting the app.

**5. Result.**

Two full tasks completed end to end. In the heavier one, three 770 KB background requests each failed 6–8 times before succeeding, and a fourth needed 9 attempts — all absorbed silently. Across all 71 requests: **82 retries, 0 gave up, 0 errors surfaced to the user.** Previously the same kind of task was being interrupted roughly every two turns.

**6. A side-by-side I didn't plan.**

I have a second machine on the **same account and the same network**, with a stock Codex install — no shim, no pruning. Over the same evening:

- Fixed machine: one transient capacity message all evening, retried and returned normally. The relay log shows **25 retries absorbed in a 12-minute stretch, 0 give-ups** — the underlying pressure is still there, it's just no longer user-visible.
- Untouched machine: still hitting "at capacity" every few turns, same hours.

Same account, same egress, same time window. The only difference is local configuration. That rules out account-level throttling, quota, region, and "the servers recovered" as explanations for the change.

**7. What I think the fix should look like.**

Shedding load is the right mechanism — a server-side queue at this scale turns into a stampede when clients time out and retry. The problem is how the shed is signalled:

- An admission failure should be a **503 with `Retry-After`**, not an `error` event inside a 200 stream. Then every reverse proxy, HTTP library and retry layer handles it without knowing anything about Codex.
- If it has to stay in-band, the client should treat `server_is_overloaded` as **retryable by default**, with backoff, instead of surfacing it.
- The default retry budget for this class should be well above 5 — the shim here needed up to 9 attempts on large bodies.
- "Try a different model" is misleading for what looks like a size-based admission decision.

**Caveats:** small samples, and the second machine isn't instrumented — that comparison is qualitative, not counted. I'd treat the size correlation as the signal and the specific percentages as noise-prone.

Happy to share the shim source if it's useful — ~450 lines of stdlib Python.
