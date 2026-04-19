#!/bin/bash
set -e

WORKSPACE="/home/runner/workspace"
LOCAL_BIN="/home/runner/.local/bin"
PYTHONLIBS="$WORKSPACE/.pythonlibs"

export PATH="$LOCAL_BIN:$PYTHONLIBS/bin:$PATH"
export PYTHONUSERBASE="$PYTHONLIBS"
export PYTHONPATH="$PYTHONLIBS/lib/python3.12/site-packages"

echo "[startup] Working directory: $(pwd)"
echo "[startup] Python: $(python3 --version)"

# ── 1. Ensure sv2v ────────────────────────────────────────────────
if [ ! -f "$LOCAL_BIN/sv2v" ]; then
  echo "[startup] Downloading sv2v v0.0.12..."
  mkdir -p "$LOCAL_BIN"
  curl -fsSL https://github.com/zachjs/sv2v/releases/download/v0.0.12/sv2v-Linux.zip -o /tmp/sv2v.zip
  unzip -o /tmp/sv2v.zip -d /tmp/sv2v_out
  cp /tmp/sv2v_out/sv2v-Linux/sv2v "$LOCAL_BIN/sv2v"
  chmod +x "$LOCAL_BIN/sv2v"
fi
echo "[startup] sv2v: $($LOCAL_BIN/sv2v --version)"

# ── 2. Build frontend ─────────────────────────────────────────────
echo "[startup] Building frontend..."
cd "$WORKSPACE/frontend"
npm install --silent 2>&1
npm run build 2>&1
cd "$WORKSPACE"
echo "[startup] Frontend built."

# ── 3. Start server ───────────────────────────────────────────────
echo "[startup] Starting Flask on 0.0.0.0:8080 ..."
cd "$WORKSPACE"

GUNICORN="$PYTHONLIBS/bin/gunicorn"

if [ -f "$GUNICORN" ]; then
  echo "[startup] Using gunicorn"
  "$GUNICORN" \
    --bind 0.0.0.0:8080 \
    --workers 1 \
    --threads 4 \
    --timeout 120 \
    --access-logfile - \
    server:app
else
  echo "[startup] gunicorn not found — using flask dev server"
  PORT=8080 python3 "$WORKSPACE/server.py"
fi
