#!/bin/bash
set -e

WORKSPACE="/home/runner/workspace"
LOCAL_BIN="/home/runner/.local/bin"
PYTHONLIBS="$WORKSPACE/.pythonlibs"

export PATH="$LOCAL_BIN:$PYTHONLIBS/bin:$PATH"
export PYTHONUSERBASE="$PYTHONLIBS"
export PYTHONPATH="$PYTHONLIBS/lib/python3.12/site-packages"

echo "[run] Starting Minion GPU on 0.0.0.0:8080..."
cd "$WORKSPACE"

"$PYTHONLIBS/bin/gunicorn" \
  --bind 0.0.0.0:8080 \
  --workers 1 \
  --threads 4 \
  --timeout 120 \
  --access-logfile - \
  server:app
