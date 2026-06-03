#!/usr/bin/env bash
set -euo pipefail

if [[ -d /work/zdock3.0.2_linux_x64 ]]; then
    cd /work/zdock3.0.2_linux_x64
else
    cd /opt/zdock
fi

exec "$@"