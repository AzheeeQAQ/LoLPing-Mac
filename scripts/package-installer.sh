#!/bin/zsh -f
# Build a self-contained macOS Installer product from the verified universal App.
set -euo pipefail
cd "${0:A:h:h}"
APP="$PWD/dist/LoLPing.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
STAGING="$PWD/.build/installer-$VERSION"
mkdir -p "$STAGING/root/Applications" "$STAGING/packages"
codesign --verify --deep --strict "$APP"
lipo "$APP/Contents/MacOS/LoLPing" -verify_arch arm64 x86_64
"$APP/Contents/MacOS/LoLPing" --check-assets
ditto "$APP" "$STAGING/root/Applications/LoLPing.app"
pkgbuild --analyze --root "$STAGING/root" "$STAGING/components.plist"
# Install at the fixed Applications path rather than relocating into a user's
# Downloads directory just because an extracted copy has the same bundle ID.
/usr/bin/python3 - "$STAGING/components.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    components = plistlib.load(f)
for component in components:
    component['BundleIsRelocatable'] = False
    component['BundleIsVersionChecked'] = False
    component['BundleHasStrictIdentifier'] = True
    component['BundleOverwriteAction'] = 'upgrade'
with open(path, 'wb') as f:
    plistlib.dump(components, f)
PY
pkgbuild --root "$STAGING/root" --component-plist "$STAGING/components.plist" \
    --identifier local.allentu.LoLPing.installer --version "$VERSION" \
    --install-location / --ownership recommended --scripts scripts/installer/pkg \
    "$STAGING/packages/LoLPing-component.pkg"
/usr/bin/python3 - "$STAGING/requirements.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as f:
    plistlib.dump({'os': ['13.0'], 'arch': ['arm64', 'x86_64']}, f)
PY
productbuild --synthesize --product "$STAGING/requirements.plist" \
    --package "$STAGING/packages/LoLPing-component.pkg" "$STAGING/Distribution.xml"
/usr/bin/python3 - "$STAGING/Distribution.xml" "$VERSION" <<'PY'
import sys, xml.etree.ElementTree as ET
path, version = sys.argv[1:]
tree = ET.parse(path)
root = tree.getroot()
ET.SubElement(root, 'title').text = f'LoLPing {version} 完整安装包'
options = root.find('options')
if options is None:
    options = ET.SubElement(root, 'options')
options.set('customize', 'never')
options.set('hostArchitectures', 'arm64,x86_64')
ET.SubElement(root, 'domains', enable_anywhere='false', enable_currentUserHome='false', enable_localSystem='true')
ET.SubElement(root, 'welcome', file='welcome.html', **{'mime-type': 'text/html'})
ET.SubElement(root, 'conclusion', file='conclusion.html', **{'mime-type': 'text/html'})
tree.write(path, encoding='UTF-8', xml_declaration=True)
PY
productbuild --distribution "$STAGING/Distribution.xml" \
    --package-path "$STAGING/packages" --resources scripts/installer/resources \
    "$PWD/dist/LoLPing-v$VERSION-complete-macOS-universal.pkg"
print "Built complete installer: dist/LoLPing-v$VERSION-complete-macOS-universal.pkg"
