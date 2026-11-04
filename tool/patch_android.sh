#!/usr/bin/env bash
# Runs after `flutter create`: label, permissions and cleartext for local servers.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/android/app/src/main/AndroidManifest.xml"
if [ ! -f "$MANIFEST" ]; then
  echo "AndroidManifest.xml not found. Run flutter create first." >&2
  exit 1
fi
python3 - "$MANIFEST" <<'PY'
import re, sys
from pathlib import Path

p = Path(sys.argv[1])
s = p.read_text()
s = re.sub(r'android:label="[^"]*"', 'android:label="Omni Chat"', s, count=1)
perms = ["android.permission.INTERNET"]
lines = ""
for name in perms:
    if f'android:name="{name}"' not in s:
        lines += f'    <uses-permission android:name="{name}" />\n'
s = s.replace('<application', lines + '    <application', 1)
# Allow http:// servers on the local network (Ollama, LM Studio).
if 'usesCleartextTraffic' not in s:
    s = s.replace('<application', '<application android:usesCleartextTraffic="true"', 1)
p.write_text(s)
PY
grep -nE 'label|uses-permission|Cleartext' "$MANIFEST"
