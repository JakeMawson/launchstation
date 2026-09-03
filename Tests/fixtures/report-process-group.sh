#!/bin/zsh
set -euo pipefail

exec /usr/bin/python3 -c 'import os, pathlib, sys; pathlib.Path(sys.argv[1]).write_text(str(os.getpgrp()), encoding="utf-8")' "$1"
