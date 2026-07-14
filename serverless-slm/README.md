# Serverless GPU SLM endpoint (RunPod + Ollama)

> **Status:** built & verified · endpoint live on RunPod Serverless (scale-to-zero) · connected to
> the client app via the native OpenAI route (Option A, no shim). Teardown documented.

Run the client app's interpreter model **`qwen3:4b-instruct`** on a **cloud GPU** so a dev fire takes
**~5 s warm** instead of the **4–13 min** it takes on the local Mac CPU — while paying **per-second only
while a request runs** (nothing when idle).

## What it does

![Serverless GPU SLM data path: client over HTTPS to a scale-to-zero RunPod endpoint running Ollama](../docs/images/serverless-slm-architecture.png)

The endpoint exposes a **standard OpenAI `chat.completions`** surface, so the client app connects with a
`base_url` + key change only — no proxy, no new dependency. Only prompt text crosses the wire — the
cloud worker never touches a database — and it scales to zero (0 cost) when idle.

## Key teaching points

- **Serverless vs VM.** Bursty dev fires fit **per-second scale-to-zero** far better than an hourly GPU
  VM (which bills full hours for a 30 s fire and needs teardown babysitting).
- **Prepaid hard cap > budget alerts.** RunPod has no percentage alerts; a prepaid $10 balance with
  **Auto-Pay off** physically caps spend — stronger than an AWS budget (which only notifies).
- **Cold vs warm.** First fire ~52 s (worker boot + 2.5 GB model pull); warm ~5 s. FlashBoot keeps
  paused workers warm during the idle window.
- **GPU fallback.** A 16 GB→24 GB priority list means a low-supply tier transparently falls back to an
  available one (observed: landed on a 24 GB PRO 6000 MIG in `EUR-IS-2`).
- **Build-your-own vs Hub.** `worker/` is a self-built Ollama image that *bakes in* the model; the live
  deployment uses the maintained **Hub Ollama worker** (faster, lower-risk) which *downloads* the model
  at cold start. The contrast is the lesson.

## Stack

| Layer | Choice |
|---|---|
| Platform | RunPod **Serverless** (scale-to-zero, per-second) |
| Serving | **Ollama** (`ollama@0.30.8`) via Hub worker `SvenBrnn/runpod-worker-ollama` |
| Model | `qwen3:4b-instruct` (set via `OLLAMA_MODEL_NAME`) |
| GPU | 16 GB (`$0.00016/s`) → 24 GB fallback |
| API | RunPod native OpenAI route `/openai/v1/...` |
| Secret | one RunPod **Restricted** API key, in local `.env` only |

## Layout

```
serverless-slm/
├── README.md                  # this file
├── RUNBOOK_SLM.md             # full build + operate guide (steps 0–5, verify gates)
├── .env.example               # template (RUNPOD_API_KEY, RUNPOD_ENDPOINT_ID, SLM_MODEL)
├── .gitignore                 # ignores .env, CV_SKILLS_SUMMARY.md, INTEGRATION_HANDOFF.md
└── worker/                    # self-built Ollama worker (learning artifact — not the deployed path)
    ├── Dockerfile             #   FROM ollama/ollama, bakes model into the image
    ├── entrypoint.sh          #   ollama serve → wait → run handler
    └── handler.py             #   RunPod handler → forwards to Ollama /v1/chat/completions
```
`CV_SKILLS_SUMMARY.md` and `INTEGRATION_HANDOFF.md` also live here locally but are **gitignored**
(a CV doc, and a handoff doc for the separate client app — neither belongs in this public repo).

## Connect a client

Any OpenAI-compatible client connects with a `base_url` + key change only. The full contract lives in
`INTEGRATION_HANDOFF.md` (kept local/gitignored). Short version:

```yaml
interpret:
  backend: openai-compat
  base_url: https://api.runpod.ai/v2/<ENDPOINT_ID>/openai/v1
  model: qwen3:4b-instruct
  api_key_env: RUNPOD_API_KEY
  timeout: 120
```

## Reproduce / operate

Follow **[`RUNBOOK_SLM.md`](RUNBOOK_SLM.md)** — account + cost guard, deploy the Hub worker, tune
scale-to-zero, smoke-test, connect, and tear down.

## Sibling projects

This repo also contains two-cloud data-engineering pipelines: [`../GCP/`](../GCP) and
[`../AWS/`](../AWS).
