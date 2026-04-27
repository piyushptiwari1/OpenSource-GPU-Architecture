#!/bin/bash
set -e

WORKSPACE="/home/runner/workspace"
LOCAL_BIN="/home/runner/.local/bin"
PYTHONLIBS="$WORKSPACE/.pythonlibs"

export PATH="$LOCAL_BIN:$PYTHONLIBS/bin:$PATH"
export PYTHONUSERBASE="$PYTHONLIBS"

echo "[build] Installing sv2v..."
mkdir -p "$LOCAL_BIN"
curl -fsSL https://github.com/zachjs/sv2v/releases/download/v0.0.12/sv2v-Linux.zip -o /tmp/sv2v.zip
unzip -o /tmp/sv2v.zip -d /tmp/sv2v_out
cp /tmp/sv2v_out/sv2v-Linux/sv2v "$LOCAL_BIN/sv2v"
chmod +x "$LOCAL_BIN/sv2v"
echo "[build] sv2v: $($LOCAL_BIN/sv2v --version)"

echo "[build] Installing Python deps..."
pip install gunicorn --user -q

echo "[build] Building frontend..."
cd "$WORKSPACE/frontend"
npm install --silent
npm run build
cd "$WORKSPACE"

echo "[build] Done — dist ready."
ls -lh "$WORKSPACE/frontend/dist/"
