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

# Some plugins are compiled against an older Android API than their own dependencies need.
# Raise every plugin module to API 36 so the AAR metadata check passes.
python3 - "$ROOT" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1]) / "android"
block = '''
subprojects {
    afterEvaluate {
        val androidExt = extensions.findByName("android")
        if (androidExt is com.android.build.gradle.BaseExtension) {
            androidExt.compileSdkVersion(36)
        }
    }
}
'''
kts = root / "build.gradle.kts"
groovy = root / "build.gradle"
if kts.exists():
    s = kts.read_text()
    if "compileSdkVersion(36)" not in s:
        marker = "subprojects {\n    project.evaluationDependsOn"
        if marker in s:
            s = s.replace(marker, block.strip() + "\n\n" + marker, 1)
        else:
            s += "\n" + block
        kts.write_text(s)
elif groovy.exists():
    s = groovy.read_text()
    if "compileSdkVersion 36" not in s:
        s += '''
subprojects {
    afterEvaluate { p ->
        if (p.hasProperty("android")) {
            p.android.compileSdkVersion 36
        }
    }
}
'''
        groovy.write_text(s)
PY
grep -n "compileSdk" "$ROOT/android/build.gradle.kts" "$ROOT/android/build.gradle" 2>/dev/null || true
