#!/usr/bin/env python3
"""Check optional Sparkle callback selectors against the shipped SDK."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
framework = root / 'macos/Pods/Sparkle'
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
  "updater:userDidMakeChoice:forUpdate:state:",
  "updaterShouldRelaunchApplication:",
  "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
  "standardUserDriverWillHandleShowingUpdate:forUpdate:state:"
]
for name in selectors {
  precondition(observer.responds(to: NSSelectorFromString(name)), "Missing Sparkle callback: \\(name)")
}
let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: observer, userDriverDelegate: observer).updater
let item = SUAppcastItem(dictionary: ["title": "Test", "sparkle:version": "999", "enclosure": ["url": "https://example.invalid/update.zip", "sparkle:version": "999"]])!
var resumed = 0
observer.setPlaybackSession("nas", active: true)
observer.setPlaybackSession("web", active: true)
precondition(observer.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { resumed += 1 }))
observer.setPlaybackSession("nas", active: false)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
precondition(resumed == 0, "A second playback session must still block restarting")
observer.setPlaybackSession("web", active: false)
// Opening a new player before the queued installer runs must retain protection.
observer.setPlaybackSession("anime", active: true)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
precondition(resumed == 0)
observer.setPlaybackSession("anime", active: false)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
precondition(resumed == 1, "Confirmed installation must resume exactly once after playback closes")
observer.setPlaybackSession("anime", active: false)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
precondition(resumed == 1)
precondition(!observer.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { resumed += 1 }))
// Start a fresh simulated cycle after the previous installation completed.
observer.cancelDeferredInstallation()
// Sparkle only calls postponement once. Repeated Install while watching must
// abort before Stage 2 instead of skipping the guard or trapping app termination.
observer.setPlaybackSession("repeat-install", active: true)
precondition(observer.updaterShouldRelaunchApplication(updater))
precondition(observer.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { resumed += 1 }))
precondition(!observer.updaterShouldRelaunchApplication(updater))
observer.setPlaybackSession("repeat-install", active: false)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
precondition(resumed == 1)
precondition(observer.updaterShouldRelaunchApplication(updater))
// Cancel after the last route closes but before the queued callback executes.
observer.setPlaybackSession("native-AVPlayer", active: true)
precondition(observer.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { resumed += 1 }))
observer.setPlaybackSession("native-AVPlayer", active: false)
observer.cancelDeferredInstallation()
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
precondition(resumed == 1, "A canceled queued installation must never resume")
// An aborted cycle must clear an outstanding deferred callback too.
observer.setPlaybackSession("native-AVPlayer-2", active: true)
precondition(observer.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { resumed += 1 }))
observer.updater(updater, didAbortWithError: NSError(domain: "fixture", code: 1))
observer.setPlaybackSession("native-AVPlayer-2", active: false)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
precondition(resumed == 1)
// The SDK resume handler can enqueue Stage 2 after our queue has finished.
do {
 let staged = NakuUpdaterObserver()
 var invoked = false
 staged.setPlaybackSession("first", active: true)
 precondition(staged.updater(updater, shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { invoked = true }))
 staged.setPlaybackSession("first", active: false)
 RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
 precondition(invoked)
 staged.setPlaybackSession("new-player-before-stage2", active: true)
 precondition(!staged.updaterShouldRelaunchApplication(updater), "A newly opened player must block the SDK's resumed Stage 2 gate")
}
print("Playback installation guard verified: overlapping sessions, queued race, exactly-once resume")
print("Sparkle delegate selectors verified: \\(selectors.count)")
''')
    executable = path / 'updater-check'
    subprocess.run(['swiftc', str(swift), '-F', str(framework), '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', str(framework), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
