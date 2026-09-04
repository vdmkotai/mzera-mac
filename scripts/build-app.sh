#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
mkdir -p dist
STAGE=$(mktemp -d "$PWD/dist/.Mzera-build.XXXXXX")
APP="$STAGE/Mzera.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Mzera "$APP/Contents/MacOS/Mzera"
xcrun -sdk macosx metal -c Sources/Mzera/Shaders.metal -o .build/Shaders.air
xcrun -sdk macosx metallib .build/Shaders.air -o "$APP/Contents/Resources/Shaders.metallib"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Mzera</string>
<key>CFBundleIdentifier</key><string>local.mzera.mac</string>
<key>CFBundleName</key><string>Mzera</string>
<key>CFBundleDisplayName</key><string>Mzera</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticGraphicsSwitching</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
python3 scripts/bundle-libraries.py "$APP"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
python3 - "$APP" <<'PY'
from pathlib import Path
import shutil
import sys
import uuid
staged=Path(sys.argv[1])
destination=Path('dist/Mzera.app').resolve()
backup=destination.with_name('.Mzera-previous-'+uuid.uuid4().hex+'.app')
if destination.exists():destination.rename(backup)
try:staged.rename(destination)
except BaseException:
    if backup.exists():backup.rename(destination)
    raise
# Existing processes keep their old inodes; never truncate a running executable.
if backup.exists():shutil.rmtree(backup)
staged.parent.rmdir()
print('Built '+str(destination))
PY
