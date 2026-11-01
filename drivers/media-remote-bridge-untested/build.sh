#!/usr/bin/env bash
# Packages driver.xml and driver.lua into MediaRemoteBridge.c4z.
# A .c4z is a zip archive with driver.xml and driver.lua at its root.
set -euo pipefail

cd "$(dirname "$0")"

OUT="MediaRemoteBridge.c4z"
FILES=(driver.xml driver.lua)

for f in "${FILES[@]}"; do
    if [ ! -f "$f" ]; then
        echo "build.sh: missing $f" >&2
        exit 1
    fi
done

rm -f "$OUT"

if command -v zip >/dev/null 2>&1; then
    zip -q -X "$OUT" "${FILES[@]}"
else
    python3 -c '
import sys, zipfile
out, files = sys.argv[1], sys.argv[2:]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in files:
        z.write(f, f)
' "$OUT" "${FILES[@]}"
fi

VERSION=$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' driver.lua)
echo "built $OUT (driver.lua VERSION ${VERSION:-unknown})"
unzip -l "$OUT"
