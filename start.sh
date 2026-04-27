#!/bin/bash
set -e

WORKSPACE="/home/runner/workspace"
LOCAL_BIN="/home/runner/.local/bin"
PYTHONLIBS="$WORKSPACE/.pythonlibs"

export PATH="$LOCAL_BIN:$PYTHONLIBS/bin:$PATH"
export PYTHONUSERBASE="$PYTHONLIBS"
export PYTHONPATH="$PYTHONLIBS/lib/python3.12/site-packages"

echo "[run] Checking sv2v..."
if [ ! -f "$LOCAL_BIN/sv2v" ]; then
  echo "[run] sv2v missing — downloading..."
  mkdir -p "$LOCAL_BIN"
  curl -fsSL https://github.com/zachjs/sv2v/releases/download/v0.0.12/sv2v-Linux.zip -o /tmp/sv2v.zip
  unzip -o /tmp/sv2v.zip -d /tmp/sv2v_out
  cp /tmp/sv2v_out/sv2v-Linux/sv2v "$LOCAL_BIN/sv2v"
  chmod +x "$LOCAL_BIN/sv2v"
fi
echo "[run] sv2v: $($LOCAL_BIN/sv2v --version)"

echo "[run] Starting Minion GPU on 0.0.0.0:5000..."
cd "$WORKSPACE"

"$PYTHONLIBS/bin/gunicorn" \
  --bind 0.0.0.0:5000 \
  --workers 1 \
  --threads 4 \
  --timeout 120 \
  --access-logfile - \
  server:app
