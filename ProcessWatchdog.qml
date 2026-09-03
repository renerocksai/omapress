import QtQuick
import Quickshell.Io

// Deadlines and termination for helper processes.
//
// Every watched process gets an absolute deadline. At the deadline it is sent
// TERM, both directly and to its process group; if it is still running after
// `killGraceMs` it gets KILL the same two ways. Quickshell's Process.signal()
// only reaches the direct child, so the group signal goes through kill(1)
// with a negative pid, which is what takes down anything the helper started
// when it was launched with --own-process-group. A process ended on purpose
// (supersede) follows the same TERM-then-KILL path.
//
// No qs.* imports on purpose: tests/watchdog-test.qml runs this file under a
// bare quickshell against a child that ignores TERM.
Item {
  id: root

  property int killGraceMs: 2000
  property int tickMs: 250
  property var watched: []        // { proc, label, deadline, termAt, pid }
  property var pendingKills: []   // { pid, at }
  property var killQueue: []

  signal timedOut(var proc, string label)

  function watch(proc, label, timeoutMs) {
    forget(proc)
    var next = watched.slice()
    next.push({ proc: proc, label: label, deadline: Date.now() + Math.max(1000, timeoutMs), termAt: undefined, pid: 0 })
    watched = next
    tick.start()
  }

  function forget(proc) {
    var next = []
    for (var i = 0; i < watched.length; i++) if (watched[i].proc !== proc) next.push(watched[i])
    watched = next
    if (watched.length === 0 && pendingKills.length === 0) tick.stop()
  }

  function pidOf(proc) {
    var pid = proc ? Number(proc.processId) : 0
    return isFinite(pid) && pid > 0 ? pid : 0
  }

  // Ends a run early on purpose: TERM now, KILL after the grace unless it
  // has exited by then. The KILL is addressed by pid because the Process
  // object is reused for the successor run.
  function supersede(proc) {
    var pid = pidOf(proc)
    terminateTree(proc)
    forget(proc)
    if (pid) {
      pendingKills = pendingKills.concat([{ pid: pid, at: Date.now() + killGraceMs }])
      tick.start()
    }
  }

  function terminateAll() {
    for (var i = 0; i < watched.length; i++) supersede(watched[i].proc)
  }

  function terminateTree(proc) {
    var pid = pidOf(proc)
    if (proc && proc.running) proc.signal(15)
    signalGroup(pid, "TERM")
  }

  function killTree(proc) {
    var pid = pidOf(proc)
    if (proc && proc.running) proc.signal(9)
    signalGroup(pid, "KILL")
  }

  function signalGroup(pid, sig) {
    if (!pid) return
    if (killQueue.length >= 64) return
    killQueue = killQueue.concat([{ pid: pid, sig: sig }])
    pumpKills()
  }

  function pumpKills() {
    if (killProcess.running || killQueue.length === 0) return
    var next = killQueue[0]
    killQueue = killQueue.slice(1)
    killProcess.command = ["kill", "-s", next.sig, "--", "-" + next.pid]
    killProcess.running = true
  }

  // Exit status ignored: a group that is already gone makes kill(1) fail,
  // and that is the outcome we wanted.
  Process {
    id: killProcess
    running: false
    command: []
    onExited: root.pumpKills()
  }

  Timer {
    id: tick
    interval: root.tickMs
    repeat: true
    onTriggered: {
      var now = Date.now()
      var still = []
      for (var i = 0; i < root.watched.length; i++) {
        var w = root.watched[i]
        if (!w.proc || !w.proc.running) continue
        if (!w.pid) w.pid = root.pidOf(w.proc)
        if (w.termAt !== undefined) {
          if (now - w.termAt >= root.killGraceMs) root.killTree(w.proc)
          else still.push(w)
          continue
        }
        if (now >= w.deadline) {
          root.terminateTree(w.proc)
          w.termAt = now
          still.push(w)
          root.timedOut(w.proc, w.label)
          continue
        }
        still.push(w)
      }
      root.watched = still

      var kills = []
      for (var k = 0; k < root.pendingKills.length; k++) {
        var pending = root.pendingKills[k]
        if (now >= pending.at) root.signalGroup(pending.pid, "KILL")
        else kills.push(pending)
      }
      root.pendingKills = kills

      if (root.watched.length === 0 && root.pendingKills.length === 0) tick.stop()
    }
  }
}
