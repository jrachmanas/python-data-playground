# RunPod serverless worker: Ollama serving qwen3:4b-instruct + a Python handler.
#
# Base = the official Ollama image (bundles the ollama binary + CUDA runtime, so it
# uses the GPU RunPod attaches to the worker automatically). We add Python + the
# RunPod SDK and override the base image's `ollama` entrypoint with our own.
FROM ollama/ollama:latest

# Bind Ollama to loopback inside the container; only our handler talks to it.
ENV OLLAMA_HOST=127.0.0.1:11434
# The single model this worker serves. Keep in sync with the client app's `model:` and .env SLM_MODEL.
ENV MODEL=qwen3:4b-instruct

# Python + the RunPod serverless SDK (the handler is Python) + curl for the readiness probe.
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip curl \
 && rm -rf /var/lib/apt/lists/*
RUN pip3 install --no-cache-dir --break-system-packages runpod requests

# Bake the model INTO the image so a cold start is load-only (no 2.5GB re-download each
# time a worker spins up). `ollama pull` only needs the server up, not a GPU, so it works
# on RunPod's CPU build machine. The pulled files land in /root/.ollama and persist in this layer.
RUN ollama serve & \
    until curl -sf http://127.0.0.1:11434/api/tags >/dev/null 2>&1 ; do sleep 1 ; done ; \
    ollama pull ${MODEL} ; \
    pkill ollama

COPY entrypoint.sh /entrypoint.sh
COPY handler.py /handler.py
RUN chmod +x /entrypoint.sh

# The base image sets ENTRYPOINT ["ollama"]; clear it so our script runs instead.
ENTRYPOINT []
CMD ["/entrypoint.sh"]
