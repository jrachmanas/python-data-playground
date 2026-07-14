"""RunPod serverless handler — thin bridge to the container's local Ollama.

RunPod invokes this for each job. The job's ``event["input"]`` is an OpenAI-style chat
body (``messages``, ``temperature``, ``max_tokens``, ...). We forward it to Ollama's
OpenAI-compatible endpoint on loopback and return the completion JSON unchanged, so the
local shim can pass it straight back to the client app.

Only prompt text ever reaches here — the worker has no database access and needs none.
"""

import os

import requests
import runpod

OLLAMA_CHAT_URL = "http://127.0.0.1:11434/v1/chat/completions"
MODEL = os.environ.get("MODEL", "qwen3:4b-instruct")


def handler(event):
    body = dict(event.get("input") or {})

    # This worker serves exactly one model; pin it so a caller can't request a missing tag.
    body["model"] = MODEL
    # Single-shot JSON response (no server-sent-event streaming across the RunPod queue).
    body["stream"] = False

    if not body.get("messages"):
        return {"error": "input.messages is required (OpenAI chat format)."}

    resp = requests.post(OLLAMA_CHAT_URL, json=body, timeout=300)
    resp.raise_for_status()
    return resp.json()


runpod.serverless.start({"handler": handler})
