# Codex Overload Fix — cockpit-tools edition

> **This is a fork.** The original project is
> [**NewBeeM4n/codex-overload-fix**](https://github.com/NewBeeM4n/codex-overload-fix) (MIT).
> The diagnosis, the measurements, the "retry only before commit" safety rule and the
> single-file relay design are **his work** — this fork only adds the parts that were
> missing when the relay runs *behind* a local gateway (cockpit-tools).
> Full change list: [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).
> If this helps you, please star the upstream repo first.

A local retry shim that stops **"Selected model is at capacity. Please try a different
model."** from interrupting your work — built for the layout where Codex already talks to
**cockpit-tools** (or any local account-pool gateway) instead of the official endpoint.

```
Codex  ──►  127.0.0.1:8788 (relay)  ──►  127.0.0.1:8888 (cockpit-tools)  ──►  upstream
```

The relay adds **one** thing to that chain: it retries the rejection that the gateway
cannot retry for you. Account rotation, session affinity, quota pool and image generation
stay with cockpit-tools, untouched.

---

## Why a fork was needed

The original shim assumes the relay sits in front of `chatgpt.com`. Behind cockpit-tools
three things break:

| Symptom | Cause | Fixed here |
|---|---|---|
| Turn hangs ~5 min when the gateway is down | Connection errors share the 30-attempt / 300 s overload budget | `--max-conn-attempts 3 --conn-budget 15` — a dead upstream now fails in seconds |
| Client shows a parse error instead of "overloaded" | Give-up returned **HTTP 200** with a JSON body while claiming `text/event-stream` | Now `503` + `Retry-After` + a JSON error |
| Overload still reaches the client despite the relay | `response.output_item.added` was treated as "content committed", but captured traffic shows **created → in_progress → output_item.added → overload** with zero text | Prelude events are a *hold*; only real content commits |
| Image tasks stall | `response.image_generation_call.*` was missing from the commit set | Image events commit |
| Gateway 503 loop gets worse | cockpit's whole-pool cooldown answers in microseconds; retrying it extends the cooldown | Detected by latency, spaced by `--cooling-wait` |
| Relay silently not protecting anything | `model_provider` gets rewritten back by the gateway app | `python tools/relayctl.py path` answers this in one line |
| `/v1/v1/responses` → 404 | `base_url` already ends in `/v1` | `--upstream` normalises a trailing `/v1` |

And one thing the original could not have known it needed: **three concurrent 790 KB
requests are a real pattern** here (measured on this machine). With per-request retries
that becomes up to 27 simultaneous punts at the gateway. A process-wide gate caps it.

`✶ Insight ─────────────────────────────────────`
The original repo's own README explains why server-side queues stampede — clients time out,
retry, and the retry traffic makes it worse. A naive client-side retry layer recreates the
same stampede *one hop lower*: N clients × K attempts, all starting at the same backoff
schedule. `--retries-per-sec` is a token bucket on retry *starts*, and
`--max-concurrent` is a semaphore on in-flight attempts, so the retry layer cannot
become the overload it is trying to absorb.
`─────────────────────────────────────────────────`

---

## Quick start (Windows, cockpit-tools users)

```powershell
git clone <this-repo>
cd codex-overload-fix-cockpit
powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -Cockpit
```

The installer:

1. finds Python 3.9+ (stdlib only, no dependencies);
2. refuses to install onto a port that is already taken — and refuses outright if you
   point it at cockpit's own port;
3. writes a hidden launcher + watchdog to `%LOCALAPPDATA%\codex-overload-fix` and
   registers it under `HKCU\...\Run` (no admin rights, no console window);
4. **copies `experimental_bearer_token` and `http_headers` out of your existing
   `[model_providers.codex_local_access]` block** into the new one — those are what
   cockpit uses to recognise the caller;
5. prints the exact config block to paste.

Then in `%USERPROFILE%\.codex\config.toml`:

```toml
model_provider = "codex_local_access_retry"

[model_providers.codex_local_access_retry]
name = "Codex API Service (retry)"
base_url = "http://127.0.0.1:8788/v1"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
experimental_bearer_token = "..."      # copied from codex_local_access
http_headers = { ... }                 # copied from codex_local_access
stream_max_retries = 20
request_max_retries = 10
```

**Fully quit and restart Codex** (tray icon → Quit, not just close the window).

Leave `experimental_realtime_ws_base_url` pointing at cockpit (`:8888`) — the relay
speaks HTTP only.

### Verify it is actually working

```powershell
python tools\relayctl.py path      # is model_provider the retry provider?
python tools\relayctl.py status    # counters: requests / retries / give-ups
python tools\relayctl.py quota     # cockpit's own account pool view
python tools\relayctl.py probe     # one tiny request, reports attempts used
```

`path` is the one that matters. A relay can be running perfectly while
`model_provider` points somewhere else — then it protects nothing, and every log line
looks healthy because there is no traffic.

### If you do *not* use cockpit-tools

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install.ps1           # port 8787
```

Uses `config\config.example.toml` (relay → `chatgpt.com`). Add
`-Proxy http://127.0.0.1:7897` if your egress needs one.

---

## What it does, exactly

**Absorbs four rejection shapes**, all before anything reaches the client:

| Shape | Where it appears |
|---|---|
| `{"type":"error", ..., "code":"server_is_overloaded"}` | inside an HTTP **200** SSE stream (the real one) |
| `response.failed` with `server_overloaded` | SSE event |
| HTTP `503` / `502` / `504` / `500` / `429` | status line (this is what cockpit produces) |
| cooling short-circuit `503` in < 200 ms | status line, cockpit-specific |

**Never retries after commit.** A commit is the first of:
`output_text.delta`, `reasoning_summary_text.delta`, `reasoning_text.delta`,
`output_item.done`, `completed`, `incomplete`, or any
`image_generation_call.partial_image / .completed`.
`response.created`, `in_progress`, `output_item.added` and `content_part.added` are
**holds**, not commits — real overload arrives right after them.

**Never leaves a stream half-written.** If overload arrives after text was sent, the
connection is dropped rather than a retry attempted, so output cannot be generated twice.

**Stops when you stop.** The client socket is polled every 200 ms; a cancelled turn or a
closed app abandons retries immediately, including during backoff sleeps.

**Fails differently by failure class.**

| Failure | Budget | Result |
|---|---|---|
| connection refused / reset | `--max-conn-attempts 3`, `--conn-budget 15s` | `503 upstream_unreachable` in seconds |
| in-band overload / gateway 503 | `--max-attempts 30`, `--total-budget 300s` | retries, spaced by a global token bucket |
| pool cooling | same, plus `--cooling-wait 5s` minimum | retries, but never hammers |
| auth / invalid request | none | passed through unchanged — that is the client's answer |

---

## Tuning

Defaults are chosen for one machine with cockpit-tools and two Plus accounts.

| flag | default | raise it when | lower it when |
|---|---|---|---|
| `--max-attempts` | 30 | you still see give-ups with >500 KB requests | you want to be conservative |
| `--total-budget` | 300 | turns that legitimately queue for minutes | you dislike long waits |
| `--max-concurrent` | 4 | you run many parallel agents | you see the gateway itself saturate |
| `--retries-per-sec` | 2 | overload windows are short | you see sustained overload (this is the anti-stampede knob) |
| `--cooling-wait` | 5 | cockpit's cooldown is long | the pool recovers instantly |
| `--commit-deadline` | 120 | — | you want first-token latency capped harder |
| `--conn-budget` | 15 | your gateway restarts take longer | — |

The single most useful number: **`retries` vs `giveups`** in `relayctl.py status`.
Retries climbing with zero give-ups means the shim is doing its job. Give-ups climbing
means the upstream window is longer than your budget, or your requests are too big —
which the shim cannot fix.

---

## The other half: send less

The shim hides the rejection. It does not create capacity. Upstream's own data (71
requests, one evening) shows the cliff:

| request body | n | mean attempts | worst |
|---|---|---|---|
| < 100 KB | 20 | 1.95 | 5 |
| 100–200 KB | 24 | 1.96 | 9 |
| 200–500 KB | 23 | 1.74 | 4 |
| **> 500 KB** | **4** | **6.75** | **9** |

Measured on this machine through the relay: single requests of **531 KB** and **791 KB**
were both served on the first attempt — so the cliff is probabilistic, not a hard
threshold. But the mean is what your retry budget has to cover.

Free levers, in order of effect:

1. **Start a new conversation.** Desktop Codex resends the whole thread every turn; a
   long thread hits `pre_compression_bytes ≈ 724,000` while a fresh one is ~89 KB.
2. **Drop skills and plugins you do not use.** 72 skills = 20.4 KB of manifest per turn.
3. **Compress attached images.** An image task can open at 700+ KB on turn one.
4. **Trim the memory block** (12.8 KB per turn, resent every turn).

`tools/capture_server.py` measures what your client actually sends.

---

## Is this safe?

- **Credentials are not touched.** Requests forward with the headers Codex already sent.
  Nothing is stored, logged or transmitted anywhere else. The relay logs request
  *sizes*, not bodies or `Authorization`.
- **Bodies are byte-identical.** Including compressed ones.
- **No quota bypass.** It re-sends a request the server already declined — the same
  action as clicking retry, just before the error reaches you.
- **It is local.** A Python process on `127.0.0.1`, no third-party server, no shared
  account pool. Delete one line from `config.toml` and you are back to direct.
- **No duplicate output**, by construction: no retry after commit.
- **On account risk:** any client that changes request timing is outside default
  behaviour. If you want to be conservative, `--max-attempts 10`.

What it **cannot** fix: an exhausted quota, an expired login, a broken network, or a
genuinely degraded model. Those are passed through unchanged.

---

## Known limits

- Windows launchers are provided; the relay itself is cross-platform.
- HTTP only. WebSocket / realtime traffic is not proxied — leave
  `experimental_realtime_ws_base_url` on cockpit.
- The global gate is in-process. Two relay instances on two ports would each have their
  own budget; run one.
- Retry budgets are per *turn*, not per conversation. A turn that keeps getting
  overloaded at every tool step will retry at every step (correctly — each step is a
  fresh request the server declined).
- Tested against Python 3.10 on Windows 11. `tests/run_tests.py` runs anywhere.

---

## Repository layout

```
relay/relay.py             the relay (single file, stdlib only)
tools/relayctl.py          status / quota / probe / path
tools/capture_server.py    measure what your client sends      (from upstream)
tools/analyze_log.py       summarise a relay.log               (from upstream)
scripts/install.ps1        hidden launcher + watchdog + config snippet
scripts/uninstall.ps1      remove autostart, stop processes
config/                    config.toml examples (cockpit / direct)
tests/run_tests.py         44 assertions, mock upstream, no deps
tests/mock_upstream.py     programmable fake upstream
```

```powershell
python tests\run_tests.py          # everything
python tests\run_tests.py --unit   # classifier only
```

---

## License

MIT. See [LICENSE](LICENSE) — the upstream copyright notice is preserved, because most
of this code is his.
