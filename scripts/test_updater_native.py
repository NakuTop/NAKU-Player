#!/usr/bin/env python3
"""Check optional Sparkle callback selectors against the shipped SDK."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
framework = root.parent / 'toolchains/sparkle-2.10.0'
source = (root / 'macos/Runner/MainFlutterWindow.swift').read_text()
observer = source[source.index('private final class NakuUpdaterObserver:'):source.index('\nclass MainFlutterWindow:')]
with tempfile.TemporaryDirectory(prefix='naku-updater-native-') as directory:
    path = Path(directory)
    swift = path / 'main.swift'
    swift.write_text('import Cocoa\nimport Sparkle\n' + observer + '''
private let observer = NakuUpdaterObserver()
let selectors = [
  "updater:didFindValidUpdate:",
  "updater:willDownloadUpdate:withRequest:",
  "updater:didDownloadUpdate:",
  "updater:willInstallUpdateOnQuit:immediateInstallationBlock:",
  "updater:didFinishUpdateCycleForUpdateCheck:error:",
  "updater:didAbortWithError:",
  "standardUserDriverWillHandleShowingUpdate:forUpdate:state:"
]
for name in selectors {
  precondition(observer.responds(to: NSSelectorFromString(name)), "Missing Sparkle callback: \\(name)")
}
print("Sparkle delegate selectors verified: \\(selectors.count)")
''')
    executable = path / 'updater-check'
    subprocess.run(['swiftc', str(swift), '-F', str(framework), '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', str(framework), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
