import QtQuick
import Quickshell
import Quickshell.Io

// Runs ProcessWatchdog against a child that ignores SIGTERM and lives in its
// own process group with a grandchild. Passes when the whole tree is gone
// within the grace after the deadline. Driven by tests/watchdog-test.sh.
ShellRoot {
  id: root

  property string marker: Quickshell.env("WATCHDOG_MARKER")
  property bool timedOutSeen: false
  property double startedAt: 0

  function finish(ok, why) {
    console.log(ok ? "WATCHDOG OK" : "WATCHDOG FAIL: " + why)
    Qt.quit()
  }

  ProcessWatchdog {
    id: watchdog
    killGraceMs: 1500
    onTimedOut: function(proc, label) {
      root.timedOutSeen = true
      console.log("timed out:", label, "after", Date.now() - root.startedAt, "ms")
    }
  }

  // The stubborn helper: own process group, TERM ignored, a grandchild that
  // must die with it. `exec` makes bash the group leader that sleeps.
  Process {
    id: stubborn
    running: false
    command: ["setsid", "-w", "bash", "-c",
      "trap '' TERM; sleep 300 & echo $! > \"$WATCHDOG_MARKER\"; wait"]
    onExited: function(code, status) {
      console.log("stubborn exited", code, "after", Date.now() - root.startedAt, "ms")
      checker.start()
    }
  }

  // Once the direct child is gone, verify the grandchild went with it.
  Timer {
    id: checker
    interval: 400
    onTriggered: {
      if (!root.timedOutSeen) { root.finish(false, "no timeout signal"); return }
      var elapsed = Date.now() - root.startedAt
      if (elapsed > 6000) { root.finish(false, "took " + elapsed + " ms"); return }
      grandchildCheck.running = true
    }
  }

  Process {
    id: grandchildCheck
    running: false
    command: ["bash", "-c", "pid=$(cat \"$WATCHDOG_MARKER\"); kill -0 \"$pid\" 2>/dev/null && echo alive || echo gone"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.finish(String(text).trim() === "gone", "grandchild survived")
    }
  }

  // Whole-test ceiling.
  Timer {
    interval: 12000
    running: true
    onTriggered: root.finish(false, "test timed out; child still running: " + stubborn.running)
  }

  Component.onCompleted: {
    root.startedAt = Date.now()
    stubborn.running = true
    watchdog.watch(stubborn, "stubborn helper", 1500)
  }
}
