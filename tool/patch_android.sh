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
perms = [
    "android.permission.INTERNET",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_DATA_SYNC",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.WAKE_LOCK",
    # Lets the user grant this app access to run commands in a separately installed Termux app
    # (declared by Termux itself, not the Android platform; harmless if Termux isn't installed).
    "com.termux.permission.RUN_COMMAND",
]
lines = ""
for name in perms:
    if f'android:name="{name}"' not in s:
        lines += f'    <uses-permission android:name="{name}" />\n'
# Package-visibility declaration (Android 11+ / targetSdk 30+): without this, the app cannot even see
# whether Termux is installed, let alone send it a command.
if '<package android:name="com.termux"' not in s:
    lines += '    <queries>\n        <package android:name="com.termux" />\n    </queries>\n'
s = s.replace('<application', lines + '    <application', 1)
# Allow http:// servers on the local network (Ollama, LM Studio).
if 'usesCleartextTraffic' not in s:
    s = s.replace('<application', '<application android:usesCleartextTraffic="true"', 1)
if 'KeepAliveService' not in s:
    svc = '        <service android:name=".KeepAliveService" android:foregroundServiceType="dataSync" android:exported="false" />\n    '
    s = s.replace('</application>', svc + '</application>', 1)
p.write_text(s)
PY
grep -nE 'label|uses-permission|Cleartext|KeepAlive' "$MANIFEST"
python3 "$ROOT/tool/keepalive.py" "$ROOT"

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

# Match the settings of an APK known to install on this phone: no R8 shrinking, plain application id.
# Release signing: Android refuses to install an update over an existing copy of the app unless both
# are signed with the same key, so CI must reuse the same key every run instead of an auto-generated
# debug one. The keystore and its passwords are never committed; they come from a CI secret (set with
# tool/set_signing_secret.sh) decoded to RELEASE_KEYSTORE_PATH by the workflow, with the passwords read
# from the environment at build time. Without that secret, the release build falls back to the debug
# signing Flutter sets up by default, which is fine for trying the app but won't update in place.
APP_KTS="$ROOT/android/app/build.gradle.kts"
APP_GRV="$ROOT/android/app/build.gradle"
if [ -f "$APP_KTS" ]; then
  sed -i 's/applicationId = "[^"]*"/applicationId = "com.codesoli.omnichat"/' "$APP_KTS"
  if ! grep -q 'isMinifyEnabled' "$APP_KTS"; then
    cat >> "$APP_KTS" <<'KTS'

android {
    val releaseKeystorePath = System.getenv("RELEASE_KEYSTORE_PATH")
    if (!releaseKeystorePath.isNullOrBlank()) {
        signingConfigs {
            create("release") {
                storeFile = file(releaseKeystorePath)
                storePassword = System.getenv("RELEASE_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("RELEASE_KEY_ALIAS")
                keyPassword = System.getenv("RELEASE_KEY_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = if (!releaseKeystorePath.isNullOrBlank()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }
    lint {
        // flutter analyze already runs as its own CI step; AGP's own lint pass here has repeatedly
        // crashed on this CI image's JDK/AGP combination with an internal NoSuchMethodError deep in
        // its own lint tooling (unrelated to anything in this app's code) rather than ever reporting
        // a real finding, so release builds skip it instead of failing on a lint-tool bug.
        checkReleaseBuilds = false
        abortOnError = false
    }
}
KTS
  fi
elif [ -f "$APP_GRV" ]; then
  sed -i 's/applicationId "[^"]*"/applicationId "com.codesoli.omnichat"/' "$APP_GRV"
  cat >> "$APP_GRV" <<'GRV'

android {
    def releaseKeystorePath = System.getenv("RELEASE_KEYSTORE_PATH")
    if (releaseKeystorePath) {
        signingConfigs {
            release {
                storeFile file(releaseKeystorePath)
                storePassword System.getenv("RELEASE_KEYSTORE_PASSWORD")
                keyAlias System.getenv("RELEASE_KEY_ALIAS")
                keyPassword System.getenv("RELEASE_KEY_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            minifyEnabled false
            shrinkResources false
            signingConfig releaseKeystorePath ? signingConfigs.release : signingConfigs.debug
        }
    }
    lintOptions {
        // flutter analyze already runs as its own CI step; AGP's own lint pass here has repeatedly
        // crashed on this CI image's JDK/AGP combination with an internal NoSuchMethodError deep in
        // its own lint tooling (unrelated to anything in this app's code) rather than ever reporting
        // a real finding, so release builds skip it instead of failing on a lint-tool bug.
        checkReleaseBuilds false
        abortOnError false
    }
}
GRV
fi
grep -n "applicationId" "$APP_KTS" "$APP_GRV" 2>/dev/null || true
