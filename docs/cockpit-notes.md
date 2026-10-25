# cockpit-tools deployment notes

Everything here was observed on one machine (Windows 11, cockpit-tools 1.3.74, Codex
desktop) and is recorded so the next person does not have to rediscover it. Numbers are
measurements, not estimates.

## Observed topology

```
Codex desktop
  │  POST http://127.0.0.1:8788/v1/responses   (relay, this repo)
  ▼
relay.py :8788
  │  POST http://127.0.0.1:8888/v1/responses   (headers byte-identical)
  ▼
cockpit-tools :8888        account pool / session affinity / image generation
  │  https://chatgpt.com/backend-api/codex/responses
  ▼
upstream
```

Ports actually occupied on this machine, for reference:

| port | owner |
|---|---|
| 7863 | local model server |
| 8787 | workbuddy2api compat server — **do not use for the relay** |
| 8788 | this relay |
| 8888 | cockpit-tools |
| 15721 | Claude shim |

## cockpit settings that interact with the relay

Read from `~/.cockpit_tools/codex_local_access.json` (re-read 2026-10-25; the file
has 47 top-level keys, and several of them that look top-level are actually nested
under `timeouts`):

| key | where | value | consequence for the relay |
|---|---|---|---|
| `gatewayMode` | top | `native` | responses stream straight through; no protocol translation to account for |
| `sessionAffinity` | top | `true` | `session-id` / `thread-id` headers must pass through untouched, or account pinning breaks silently |
| `sessionAffinityTtlMs` | top | `3600000` (1 h) | affinity expires hourly; a long turn can change accounts mid-conversation |
| `disableCooling` | top | `true` | the gateway no longer short-circuits on its own; the relay is the only retry layer |
| `maxRetryCredentials` | top | `0` | the gateway will not swap accounts on failure — retrying at the relay is the only path that recovers |
| `maxRetryIntervalMs` | top | `3000` | gateway-side ceiling |
| `upstreamSendRetryAttempts` | **`timeouts`** | `3` | see below — one relay attempt can fan out into 3 upstream sends |
| `singleAccountStatusRetryAttempts` | **`timeouts`** | `2` | gateway-internal retries are shallow; do not rely on them |
| `legacyStreamTotalTimeoutMs` | **`timeouts`** | `300000` | equals the relay's default `--total-budget`; change them together or one silently truncates the other |
| `legacyStreamIdleTimeoutMs` | **`timeouts`** | `120000` | equals the relay's default `--commit-deadline` |
| `responsesWebsocketsEnabled` | top | `false` | the realtime channel is not in the HTTP path |
| `imageGenerationMode` | top | `enabled` | image events must count as committed |
| `imageGenerationModel` | top | `gpt-image-2.5` | separate key from `imageGenerationMode` |
| `maxConcurrentImageRequests` | top | `1` | image turns serialise at the gateway |
| `requestPayloadLogging` | top | `true` | cockpit can capture payloads; the relay deliberately does not |

Three of these matter most:

**`sessionAffinity = true`.** The relay's `forward_headers()` drops only hop-by-hop
headers. It must never normalise, rewrite or synthesise `session-id`, `thread-id`,
`x-codex-*`. If you fork this again and add header logic, keep that invariant.

**`disableCooling = true`.** With cooling enabled, cockpit answered heavy pools with a
~40 ms local 503. That short-circuit is faster than any real upstream round trip, which is
why `relay.py` classifies a 503 arriving in under 200 ms as cooling and applies
`--cooling-wait` rather than immediately retrying. Retrying a cooling pool extends the
cooldown.

**`upstreamSendRetryAttempts = 3` is a multiplier on every relay attempt.** This is the
non-obvious one. When the gateway accepts a request and its own upstream send fails, it
retries up to 3 times internally before answering the relay. So one `attempt()` in the
relay log can mean up to three real upstream sends, and the relay's 30-attempt budget is
not the same as 30 upstream sends. Two consequences:

- The effective ceiling is roughly `--max-attempts × 3`. If you are reasoning about load
  on the upstream, that is the number to reason about.
- A "single attempt succeeded" in the relay log does not prove the upstream saw one
  request. It proves the relay made one *call*.

The gateway applies these retries on its own schedule (base 200 ms, max 1200 ms), so the
relay's backoff and the gateway's backoff are independent and can interleave. This is
harmless — the relay's job is still to absorb the rejection the gateway surfaces — but it
means the two layers' attempt counts cannot be reconciled one-to-one.

Also note `sidecarStreamOpenMaxAttempts = 1` and `sidecarStreamingBootstrapRetries = 1`:
the sidecar path opens the stream exactly once and does not re-establish a failed open.
That is the slot the relay occupies.

## The silent-failure trap

cockpit-tools writes `config.toml` on account switches. On 2026-10-24 the relay was
installed and `model_provider` was set to `codex_local_access_retry`; by the next check it
read `codex_local_access` again. The relay was listening, the watchdog was healthy, the
log showed periodic `/v1/cockpit/quota` polls through it — and **zero** `/responses`
traffic, because Codex was talking to `:8888` directly.

Everything about that state looks fine from the relay's side. That is why
`tools/relayctl.py path` exists: it reads `model_provider` out of `config.toml` and prints
whether the relay is in the path. Run it before believing any log.

## Measured traffic through the relay

Real desktop turns, `relay.log`, after the relay was placed in front of cockpit:

| time | body | model | attempts | outcome |
|---|---|---|---|---|
| 21:11:12 | 211 B | gpt-6.1-sol | 1 | ok |
| 21:13:46 | 171,344 B | gpt-5.6-luna | 1 | ok |
| 21:13:46 | **798,145 B** | gpt-5.6-luna | 1 | ok |
| 21:13:57 | 107,608 B | gpt-6.1-sol | 1 | ok |
| 21:15:56 | 108,459 B | gpt-6.1-sol | 1 | ok |
| 21:17:31 | 107,271 B | gpt-6.1-sol | 1 | ok |
| 23:54:50 | 531,160 B | gpt-5.6-luna | 1 | ok |
| 23:54:50 | 790,859 B | gpt-5.6-luna | 1 | ok |
| 23:54:51 | 104,765 B | gpt-6.1-sol | 1 | ok |

Two readings:

1. **799 KB is normal here**, not an outlier. Three of nine requests were over 500 KB.
   The upstream README's "big requests are the opening move" holds: these arrive in the
   first seconds of a task.
2. **Zero retries in this window.** The upstream did not reject anything while the relay
   was watching, so production retry behaviour is still unobserved. The retry path is
   proven by `tests/run_tests.py` against a mock, not by a real overload window.

Do not read "0 retries" as "the shim is unnecessary". The window is one evening.

## Verified against the live gateway (2026-10-25)

A minimal non-streaming request through the relay (`curl` with the cockpit bearer token
and headers), 6.6 s to first event, `served=gpt-5.6-luna`, stream complete. Request bodies
are not logged; only size and a decomposed size breakdown (`model`, `effort`, `tier`,
`instructions`, `tools`, `input`, `cache_key`).

`tools/relayctl.py probe` against the same gateway, twice, after the non-streaming fix:

```
probe  http 200  4.4s  2013B  attempts=1 retries=0
probe  http 200  5.9s  2028B  attempts=1 retries=0
```

## The non-streaming trap in `probe`

Worth recording because it produced the worst log this repo has seen. `probe` sends
`"stream": false`, and cockpit answers `application/json` — not SSE. Before the
content-type check, the relay read that body to EOF, found no `data:` events, and
concluded `stream ended early`, which is a *retryable* classification. Measured on the
pre-fix build: **17 retries, 0 give-ups, 0 overload events, one request stuck in flight**
until the client timed out.

```
req 3   upstream attempts 19   retries issued 17
  of which then succeeded 0    in-band overload events 0
  connection errors 0          gave up (503 to client) 0
  in flight now 1
```

Note the shape of that failure: every retry counter says "not overload", which is the
tell. A retry storm with **zero** overload events and **zero** connection errors is a
classifier bug, not upstream pressure. If you see that signature again, check
`Content-Type` handling before touching the budgets.

The second lesson is about process lifecycle. That measurement came from a watchdog-
relaunched instance that had been *started* before the fix — the file on disk was new,
the bytecode in memory was old. Kill the watchdog before the relay, and verify a fix
with a freshly started process.

## Port collisions on this machine

`relayctl.py status` used to print "is it running?" for any non-200, including a 404.
But a 404 means a process *is* listening — it simply has no `/__relay/health` endpoint.
Port 8788 was held by upstream's build (no health endpoint) while this fork was being
tested, so the relay read as "not running" when it was only old. The check now
distinguishes "no health endpoint" from "no connection" and prints the `Get-CimInstance`
command needed to identify the owner.

## Quota observation

`/v1/cockpit/quota` reports a pool, not an account:

```
accounts 2/2 available, five-hour 112% remaining, weekly 186%, cooling 0
```

`>100%` is cockpit's own arithmetic across accounts (two Plus accounts, each with its own
window). It is not a signal that the upstream has spare capacity — admission is decided
per request, by size, which is the whole problem.
