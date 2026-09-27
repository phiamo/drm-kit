#!/usr/bin/env bash
# Prints "udid=<id>" for a booted-capable iPhone simulator on the newest installed iOS <major>.x
# runtime, downloading that runtime first when the runner image does not ship it.
set -euo pipefail
MAJOR="$1"

runtime_id() {
  xcrun simctl list runtimes -j | python3 -c "
import json, sys
major = sys.argv[1]
rts = [r for r in json.load(sys.stdin)['runtimes']
       if r.get('platform') == 'iOS' and r['isAvailable'] and r['version'].split('.')[0] == major]
rts.sort(key=lambda r: [int(x) for x in r['version'].split('.')])
print(rts[-1]['identifier'] if rts else '')
" "$MAJOR"
}

RUNTIME=$(runtime_id)
if [ -z "$RUNTIME" ]; then
  # Newest public build of that major that Apple still serves.
  case "$MAJOR" in
    15) BUILD=15.5 ;; 16) BUILD=16.4 ;; 17) BUILD=17.5 ;; *) BUILD="$MAJOR.0" ;;
  esac
  echo "Downloading iOS $BUILD simulator runtime" >&2
  sudo xcodebuild -downloadPlatform iOS -buildVersion "$BUILD" >&2
  RUNTIME=$(runtime_id)
fi
[ -n "$RUNTIME" ] || { echo "No iOS $MAJOR runtime available" >&2; exit 1; }
echo "Runtime: $RUNTIME" >&2

# Pick an iPhone device type this runtime supports (older runtimes lack new models and vice versa).
for TYPE in $(xcrun simctl list devicetypes -j | python3 -c "
import json, sys
for d in json.load(sys.stdin)['devicetypes']:
    if d['productFamily'] == 'iPhone':
        print(d['identifier'])
" | sort -r); do
  if UDID=$(xcrun simctl create "CI iOS $MAJOR" "$TYPE" "$RUNTIME" 2>/dev/null); then
    echo "Device: $TYPE" >&2
    echo "udid=$UDID"
    exit 0
  fi
done
echo "No iPhone device type supports $RUNTIME" >&2
exit 1
