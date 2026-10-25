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

Read from `~/.cockpit_tools/codex_local_access.json`:

| key | value | consequence for the relay |
|---|---|---|
| `gatewayMode` | `native` | responses stream straight through; no protocol translation to account for |
| `sessionAffinity` | `true`, TTL 1 h | `session-id` / `thread-id` headers must pass through untouched, or account pinning breaks silently |
| `disableCooling` | `true` | the gateway no longer short-circuits on its own; the relay is the only retry layer |
| `maxRetryCredentials` | `0` | the gateway will not swap accounts on failure — retrying at the relay is the only path that recovers |
| `singleAccountStatusRetryAttempts` | `2` | gateway-internal retries are shallow; do not rely on them |
| `responsesWebsocketsEnabled` | `false` | the realtime channel is not in the HTTP path |
| `imageGenerationMode` | `enabled`, model `gpt-image-2.5` | image events must count as committed |
| `requestPayloadLogging` | `true` | cockpit can capture payloads; the relay deliberately does not |

Two of these matter most:

**`sessionAffinity = true`.** The relay's `forward_headers()` drops only hop-by-hop
headers. It must never normalise, rewrite or synthesise `session-id`, `thread-id`,
`x-codex-*`. If you fork this again and add header logic, keep that invariant.

**`disableCooling = true`.** With cooling enabled, cockpit answered heavy pools with a
~40 ms local 503. That short-circuit is faster than any real upstream round trip, which is
why `relay.py` classifies a 503 arriving in under 200 ms as cooling and applies
`--cooling-wait` rather than immediately retrying. Retrying a cooling pool extends the
cooldown.

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
and headers), 6.6 s to first event, `served=gpt-5.6-luna`, stream complete. The relay
logged `attempt 1: ok, streaming`. Request bodies are not logged; only size and a
decomposed size breakdown (`model`, `effort`, `tier`, `instructions`, `tools`, `input`,
`cache_key`).

## Quota observation

`/v1/cockpit/quota` reports a pool, not an account:

```
accounts 2/2 available, five-hour 112% remaining, weekly 186%, cooling 0
```

`>100%` is cockpit's own arithmetic across accounts (two Plus accounts, each with its own
window). It is not a signal that the upstream has spare capacity — admission is decided
per request, by size, which is the whole problem.
