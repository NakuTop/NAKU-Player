#!/usr/bin/env python3
"""Check that a built Mac app contains native light/dark Icon Composer stacks."""
from pathlib import Path
import json
import plistlib
import subprocess
import sys

app = Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
name = info.get('CFBundleIconName')
if name != 'NakuAppIcon' or info.get('CFBundleIconFile') != name:
    raise ValueError('Bundle still points at a static/legacy icon')
resources = app / 'Contents/Resources'
if not (resources / (name + '.icns')).is_file():
    raise ValueError('Legacy macOS fallback icon missing')
assets = json.loads(subprocess.check_output(['xcrun', 'assetutil', '--info', str(resources / 'Assets.car')]))
stacks = {row.get('Appearance'): row for row in assets
          if row.get('Name') == name and row.get('AssetType') == 'IconImageStack'}
light, dark = (stacks.get(key) for key in ('NSAppearanceNameAqua', 'NSAppearanceNameDarkAqua'))
if not light or not dark:
    raise ValueError('Native system light/dark icon stacks missing')
light_fill, dark_fill = (row['Layers'][0]['Name'] for row in (light, dark))
if light_fill == dark_fill:
    raise ValueError('Both appearances still use the same icon background')
print(json.dumps({'bundle_icon': name, 'native_light_stack': True, 'native_dark_stack': True,
                  'distinct_backgrounds': True, 'legacy_fallback_present': True}))
