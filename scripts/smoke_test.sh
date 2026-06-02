#!/usr/bin/env bash
set -euo pipefail

exec "$(dirname "$0")/app_smoke_test.sh"
