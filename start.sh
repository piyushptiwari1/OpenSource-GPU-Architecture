#!/bin/bash
set -e

export PATH="/home/runner/.local/bin:/home/runner/workspace/.pythonlibs/bin:$PATH"
export PYTHONUSERBASE=/home/runner/workspace/.pythonlibs
export PYTHONPATH=/home/runner/workspace/.pythonlibs/lib/python3.12/site-packages

echo "==> Checking sv2v..."
if [ ! -f /home/runner/.local/bin/sv2v ]; then
  echo "==> Installing sv2v v0.0.12..."
  mkdir -p /home/runner/.local/bin
  curl -fsSL https://github.com/zachjs/sv2v/releases/download/v0.0.12/sv2v-Linux.zip -o /tmp/sv2v.zip
  unzip -o /tmp/sv2v.zip -d /tmp/sv2v_out
  cp /tmp/sv2v_out/sv2v-Linux/sv2v /home/runner/.local/bin/sv2v
  chmod +x /home/runner/.local/bin/sv2v
fi
echo "==> sv2v: $(/home/runner/.local/bin/sv2v --version)"

echo "==> Building frontend..."
cd /home/runner/workspace/frontend
npm install --silent
npm run build
cd /home/runner/workspace

echo "==> Starting Minion GPU server on port 8080..."
gunicorn \
  --bind 0.0.0.0:8080 \
  --workers 1 \
  --threads 4 \
  --timeout 120 \
  --access-logfile - \
  server:app
