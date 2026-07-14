#!/usr/bin/env bash
# Container start: bring Ollama up in the background, wait until it answers, then hand
# control to the RunPod serverless worker (which blocks, polling RunPod's job queue).
set -euo pipefail

# Start the Ollama server (loads the baked-in model onto the GPU on first request).
ollama serve &

# Wait until the local API is ready before accepting jobs.
until curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1; do
  sleep 1
done
echo "Ollama is ready — starting RunPod worker."

# Foreground process = the RunPod serverless loop. `exec` so signals reach it cleanly.
exec python3 -u /handler.py
