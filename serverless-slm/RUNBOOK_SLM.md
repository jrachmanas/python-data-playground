# Runbook — Serverless GPU SLM endpoint (RunPod + Ollama)

**Goal.** Run the client app's interpreter model `qwen3:4b-instruct` on a **cloud GPU** so a dev fire
takes **seconds** instead of the 4–13 min it takes on the local Mac CPU. Nothing about the client app's
logic changes — only the *model server* moves to the cloud, reached through the **OpenAI-compatible
`/v1` surface** the client app already speaks.

**What crosses the wire.** Only the assembled *prompt text* (the grounding + numeric snapshot the
pipeline already built locally). The cloud worker **never touches any database** — it can't reach the
LAN DB and doesn't need to.

**Provider / shape (decided).** **RunPod Serverless** · Ollama worker · **scale-to-zero** (pay
per-second only while a request runs). Chosen over an hourly VM because bursty dev fires fit
per-second billing far better — no idle cost, no teardown babysitting.

**Connection (decided — Option A "direct").** The client app points its `base_url` straight at RunPod's
**native OpenAI-compatible route** (`.../openai/v1`). No local proxy/shim is needed — RunPod's job
API is wrapped transparently behind a real `chat.completions` endpoint. The exact handoff contract is
in `INTEGRATION_HANDOFF.md` (kept **local/gitignored** — it's a handoff for the separate client app,
not part of this public repo).

---

## How to use this doc
- Steps are **numbered and sequential**. Each ends with a **✅ Verify** gate — see it before moving on.
- Commands are labelled `[MAC]` (your laptop) or `[RUNPOD]` (done in the RunPod web console).
- The only secret is the **RunPod API key**; it lives in a local `.env` (gitignored) and nowhere else.
- Placeholders in this doc: `<ENDPOINT_ID>` = your serverless endpoint id (kept out of git; it lives in
  your local `.env` as `RUNPOD_ENDPOINT_ID`). `<RUNPOD_API_KEY>` = your secret key (local `.env` only).

---

## Step 0 — Account & cost guard `[RUNPOD]`

RunPod does **not** use AWS/GCP-style percentage budget alerts. Its guard is a **prepaid hard ceiling**,
which is actually *stronger* — with no auto-reload, you physically cannot spend past what you loaded.

1. Sign up at runpod.io. Choose **Serverless** (auto-scaling endpoint), **not Pods** (Pods = an hourly
   always-on VM — the shape we rejected; RunPod's onboarding "recommends" Pods generically, ignore that).
2. **Billing → Load $10** ("Other" = 10 → Pay with card). Adds your card and loads a $10 balance.
3. **Keep Auto-Pay DISABLED.** The key setting: with a prepaid balance and no auto-reload, when the
   balance hits $0 workloads simply stop — RunPod can't silently re-charge your card. Your $10 is a true
   hard cap (stronger than an AWS budget, which only emails you).
4. **Spend limit** shows ~$80/hr by default — that's a *rate* cap, not a total. Lower it (~$5/hr) if
   editable, as defense-in-depth. Our real spend rate is fractions of a cent per request.
5. **Settings → Connections → connect GitHub** — lets RunPod build a worker image from a repo in the
   cloud (no local Docker). Safe: worker code has no secrets.
6. **Settings → API Keys → Create → Restricted:** set `api.runpod.io/graphql` = **None** (no
   account-management power) and `api.runpod.ai` = **Read/Write** (inference only). This is least
   privilege — the key can run inference but cannot delete resources or change billing. Copy it once,
   store it safely. It goes into the local `.env` in Step 1 — **never** into git.

**✅ Verify Step 0:** $10 balance · Auto-Pay **Disabled** · GitHub connected · a **Restricted** API key
exists (kept secret). No endpoint deployed yet → **current spend = $0.00/hr**.

---

## Step 1 — Local scaffolding `[MAC]`

Folder `serverless-slm/` holds:
- `.gitignore` — ignores `.env` and `CV_SKILLS_SUMMARY.md` (also caught by root `CV_*.md`).
- `.env.example` — template for `RUNPOD_API_KEY`, `RUNPOD_ENDPOINT_ID`, `SLM_MODEL`.
- `worker/` — a self-built Ollama worker image (Step 2). *Kept as a learning artifact; the actual
  deployment used the RunPod Hub Ollama worker — see Step 3 for why.*
- `README.md`, `RUNBOOK_SLM.md`, `INTEGRATION_HANDOFF.md` — the docs.

Copy the template and fill the key (no key in shell history):

```bash
# [MAC] from serverless-slm/
cp .env.example .env
read -rs 'RUNPOD_API_KEY?Paste RunPod API key: '; echo
sed -i '' "s|^RUNPOD_API_KEY=.*|RUNPOD_API_KEY=${RUNPOD_API_KEY}|" .env
unset RUNPOD_API_KEY
grep -c '^RUNPOD_API_KEY=.\+' .env   # prints 1 if the key line is non-empty
```

**✅ Verify Step 1:** `.env` exists, key line non-empty, and `git status` never shows `.env`
(it's gitignored).

---

## Step 2 — Build the Ollama-in-container worker `[MAC]` + `[RUNPOD]`  *(learning artifact)*

Three files under `worker/` make one container — this is the "build-it-yourself" path:

- **`Dockerfile`** — `FROM ollama/ollama` (ollama binary + CUDA). Adds Python + the `runpod` SDK, then
  **bakes the model into the image** during build (`ollama serve &` → wait → `ollama pull
  qwen3:4b-instruct`) so a cold start is *load-only*, not a 2.5 GB download. Clears the base image's
  `ollama` entrypoint and runs our `entrypoint.sh`.
- **`entrypoint.sh`** — starts `ollama serve` in the background, waits until `:11434` answers, then
  `exec`s the Python handler (which blocks polling RunPod's job queue).
- **`handler.py`** — the RunPod serverless handler. Each job's `event["input"]` is an OpenAI-style body
  forwarded to Ollama's local `/v1/chat/completions`, returning the completion JSON. Pins `model` +
  `stream=False`. **No DB access — only prompt text arrives here.**

Build path = GitHub (no local Docker). Committed to the public repo (no secrets in worker code):

```bash
# [MAC] from the repo root
git add serverless-slm/ && git commit -m "serverless-slm: worker + scaffolding" && git push
```

**Why we did NOT deploy this one.** The RunPod **Hub** ships a maintained, community-tested Ollama
serverless worker (`SvenBrnn/runpod-worker-ollama`, 29★) that takes any model via one env var
(`OLLAMA_MODEL_NAME`) and already exposes the OpenAI route. For a first working endpoint it's faster
and lower-risk than debugging a bespoke image build. **Tradeoff we accepted:** the Hub worker
*downloads* the model at cold start (our own image would have *baked* it in). We keep `worker/` as the
artifact that shows the baked-in approach and the container internals.

**✅ Verify Step 2:** three files under `worker/` on GitHub; no `.env` staged
(`git status --porcelain | grep -i '\.env$'` returns nothing).

---

## Step 3 — Deploy the serverless endpoint via the Hub `[RUNPOD]`

1. **Hub → Serverless Repos →** search `ollama` → open **Runpod Worker Ollama** by **SvenBrnn**
   (`ollama@0.30.8`, 29★). This one runs real **Ollama** (not vLLM), so cloud outputs match local
   `qwen3:4b-instruct` faithfully.
2. **Deploy →** env-var step: set **Model Name = `qwen3:4b-instruct`** (becomes `OLLAMA_MODEL_NAME` —
   the exact tag the client app uses). Leave Advanced (Max Concurrency 8) default. **Next.**
3. **GPU:** check **16 GB** (1st, `$0.00016/s` ≈ $0.58/hr) and **24 GB** (2nd fallback). A 4B model
   (~2.5 GB) fits in 16 GB with room to spare; the "not recommended" warning is RunPod nudging bigger
   PRO cards — safe to ignore. **Create Endpoint** (first billable action; still $0 until a request runs).
4. **Endpoint page → Manage → Edit Endpoint:** **Max workers = 1**, **Active workers = 0**
   (scale-to-zero — the $0-idle guard), **Idle timeout = 5 s**, **FlashBoot = ON** (free; pauses idle
   workers to cut cold starts). Confirm env `OLLAMA_MODEL_NAME = qwen3:4b-instruct`. **Save.**
5. Copy the **Endpoint ID** into `.env` as `RUNPOD_ENDPOINT_ID`.

**Smoke test `[MAC]`** (loads both values from `.env`, so no secrets typed):

```bash
cd serverless-slm && set -a; source .env; set +a
# Native OpenAI chat route — the one the client app will use:
curl -s -X POST "https://api.runpod.ai/v2/${RUNPOD_ENDPOINT_ID}/openai/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${RUNPOD_API_KEY}" \
  -d '{"model":"qwen3:4b-instruct","messages":[{"role":"user","content":"Say exactly: Hello from RunPod"}]}'
```

Expected (native `chat.completion`, no wrapper):
```json
{"choices":[{"finish_reason":"stop","index":0,"message":{"content":"Hello from RunPod","role":"assistant"}}],
 "model":"qwen3:4b-instruct","object":"chat.completion","usage":{"total_tokens":20},...}
```

**Observed behaviour (worth knowing):**
- **Cold vs warm.** First fire = **~52 s** (`delayTime`) while a worker spins up + downloads the model;
  it may return `status:IN_PROGRESS` with a job id. Warm fire = **~5 s total** (`delayTime` ~1.2 s +
  `executionTime` ~3.7 s). FlashBoot keeps the worker warm during the idle window.
- **GPU fallback works.** With 16 GB low-supply, the worker landed on a **24 GB (PRO 6000 MIG)** in
  `EUR-IS-2` — exactly the fallback we configured.
- **`/runsync` results are consumed-once.** Polling `/status/<id>` after the sync call already returned
  gives `404 job not found` — the result was purged. Just re-fire (warm) to see output inline.
- **Two input shapes.** `{"input":{"prompt":"..."}}` → legacy `text_completion` (`output[]` array,
  `choices[].text`). The `/openai/v1/chat/completions` route → native `chat.completion`
  (`choices[].message.content`). **The client app uses the latter.**

**✅ Verify Step 3:** the native-route curl returns a `chat.completion` with the model's text; Workers
tab shows the worker returning to **idle** (scale-to-zero) after ~5 s; balance barely moved.

---

## Step 4 — Connect the client app (Option A — direct)  `[client-app repo]`  *(theoretical — done in the separate repo)*

This step is **out of scope for this repo** — the client app is a separate project, and the actual
interpret-run test happens there, not here. It's documented for completeness only. RunPod's native
OpenAI route means **no shim is required**: the client app connects with a `base_url` + key change only.
Full contract in `INTEGRATION_HANDOFF.md` (local/gitignored). In short:

```yaml
interpret:
  backend: openai-compat
  base_url: https://api.runpod.ai/v2/<ENDPOINT_ID>/openai/v1
  model: qwen3:4b-instruct
  api_key_env: RUNPOD_API_KEY   # read from env, never hard-coded
  timeout: 120                  # must exceed the ~52 s cold start
```

*Why not a local shim (Option B)?* A shim (`localhost:11500/v1` → RunPod) would keep the key out of
the client app's config and mirror local-Ollama parity, but it adds a process to run/maintain for no
price/speed gain. With the native route already OpenAI-shaped, a shim is over-engineering here. The
tradeoff we accepted: the client app holds the RunPod key (via env var) and its `base_url` differs from the
local-Ollama one.

**✅ Verify Step 4 (theoretical, in the client app's repo):** one interpret run returns a grounded answer;
the first run is slow (cold start), later runs are fast. Not executed or verified from this repo.

---

## Step 5 — Deliverables & teardown

**Deliverables (in this folder):**
- `RUNBOOK_SLM.md` (this doc) — build + operate guide. *(committed)*
- `README.md` — front-door overview. *(committed)*
- `worker/` — the self-built worker image (learning artifact). *(committed)*
- `INTEGRATION_HANDOFF.md` — handoff contract for the client app. *(local/gitignored)*
- `CV_SKILLS_SUMMARY.md` — skills writeup. *(local/gitignored; separate CV project)*

**Teardown (when done experimenting) `[RUNPOD]`:**
1. Serverless → the endpoint → **Manage → Delete Endpoint**. (With scale-to-zero there's no idle cost,
   but delete to keep the account clean.)
2. Optional: leave the $10 balance for next time, or it simply sits there (no auto-decay from a deleted
   endpoint). Auto-Pay stays disabled either way.
3. The **API key** can be revoked in Settings → API Keys if you're fully done.

**✅ Verify teardown:** Serverless list empty · current spend `$0.00/hr` · local `.env` still holds the
values so the stack is one deploy away from rebuild.

---

## Do-NOT list
- **Do NOT enable Auto-Pay** — it defeats the prepaid hard cap.
- **Do NOT commit `.env`**, the API key, or the real endpoint id into git.
- **Do NOT give the worker any database access** — only prompt text crosses the wire.
- **Do NOT leave `Active/min workers > 0`** — that keeps a GPU warm (standing cost). Use scale-to-zero.
- **Do NOT hard-code the RunPod key in the client app's `config.yaml`** — read it from an env var, and keep
  the cloud `base_url` edit local/temporary.
