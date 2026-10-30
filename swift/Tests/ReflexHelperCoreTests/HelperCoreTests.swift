import Foundation
import XCTest

@testable import ReflexHelperCore
@testable import ReflexKit

func tempHome() -> URL {
  let url = URL(fileURLWithPath: "/tmp").appendingPathComponent("rxh-\(UUID().uuidString.prefix(8))", isDirectory: true)
  try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

final class OutboxTests: XCTestCase {
  func testPersistAckReplayAndCompact() throws {
    let dir = tempHome()
    var box: Outbox? = try Outbox(directory: dir)
    for i in 0..<5 { try box!.append(kind: "event", id: "e\(i)", data: ["i": JSON(i)]) }
    try box!.ack(upTo: 2)
    XCTAssertEqual(box!.pending().map(\.id), ["e2", "e3", "e4"])
    box = nil
    // Reload: unacknowledged items survive, sequence numbers continue.
    let again = try Outbox(directory: dir)
    XCTAssertEqual(again.pending().map(\.seq), [3, 4, 5])
    XCTAssertEqual(again.pending(after: 4).map(\.id), ["e4"])
    let next = try again.append(kind: "task.result", id: "result:t", data: [:])
    XCTAssertEqual(next.seq, 6)
    try again.ack(upTo: 6)
    XCTAssertEqual(again.depth, 0)
    for i in 0..<2500 { try again.append(kind: "event", id: "x\(i)", data: [:]) }
    try again.ack(upTo: again.lastSeq)
    let lines = try String(contentsOf: dir.appendingPathComponent("outbox.jsonl"), encoding: .utf8).split(separator: "\n").count
    XCTAssertLessThan(lines, 100, "acknowledged items are compacted away")
  }
}

/// Supervises the real `reflex-testprog` binary.
final class ProgramManagerTests: XCTestCase {
  var home: URL!
  var manager: ProgramManager!
  var queue: DispatchQueue!
  var outbox: Outbox!
  let items = Locked([OutboxItem]())

  static var testprog: URL {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [".build/debug/reflex-testprog", ".build/arm64-apple-macosx/debug/reflex-testprog"].map { root.appendingPathComponent($0) }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? candidates[0]
  }

  override func setUpWithError() throws {
    guard FileManager.default.isExecutableFile(atPath: Self.testprog.path) else { throw XCTSkip("build reflex-testprog first") }
    home = tempHome()
    let paths = HelperPaths(dshHome: home)
    try paths.prepare()
    let dir = paths.programsDir.appendingPathComponent("testprog", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: Self.testprog, to: dir.appendingPathComponent("testprog"))
    let manifest = Process()
    manifest.executableURL = dir.appendingPathComponent("testprog")
    manifest.arguments = ["--manifest"]
    let out = Pipe()
    manifest.standardOutput = out
    try manifest.run()
    manifest.waitUntilExit()
    try out.fileHandleForReading.readDataToEndOfFile().write(to: dir.appendingPathComponent("manifest.json"))
    queue = DispatchQueue(label: "test.helper")
    outbox = try Outbox(directory: paths.stateDir)
    manager = queue.sync { ProgramManager(paths: paths, queue: queue, outbox: outbox) }
    queue.sync {
      manager.config.pingInterval = 0.3
      manager.config.pongTimeout = 2
      manager.config.maxBackoff = 0.3
      manager.config.maxFailures = 3
      manager.config.defaultStopGrace = 1.5
      manager.onOutbox = { [items] item in items.withLock { $0.append(item) } }
      manager.start()
    }
  }

  override func tearDown() {
    let done = DispatchSemaphore(value: 0)
    queue?.async { self.manager.shutdownAll { done.signal() } }
    _ = done.wait(timeout: .now() + 10)
  }

  func status(_ id: String = "testprog") -> [String: JSON] {
    queue.sync { manager.statusJSON().array?.first { $0["id"]?.string == id }?.object ?? [:] }
  }

  func wait(_ what: String, timeout: Double = 10, _ cond: () -> Bool) {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
      if cond() { return }
      usleep(50_000)
    }
    XCTFail("timed out waiting for \(what); status: \(status())")
  }

  func result(_ taskId: String) -> OutboxItem? {
    items.current.first { $0.kind == "task.result" && $0.data["taskId"]?.string == taskId }
  }

  func enable(_ on: Bool = true, required: Bool = true, config: [String: JSON] = [:]) {
    queue.sync {
      manager.configure([ProgramDesired(id: "testprog", enabled: on, required: required, config: config)], replaceAll: true)
      manager.setRunningApps(["com.apple.finder"])
    }
  }

  func testStartsOnDemandAndStopsWhenDisabled() {
    enable(false)
    usleep(500_000)
    XCTAssertNil(status()["pid"])
    enable(true)
    wait("running") { status()["state"]?.string == "running" }
    wait("started event") { items.current.contains { $0.data["eventType"]?.string == "testprog.started" } }
    enable(false)
    wait("stopped") { status()["pid"] == nil }
  }

  func testEchoAndStopOnTasks() throws {
    enable()
    wait("running") { status()["state"]?.string == "running" }
    _ = try queue.sync { try manager.startTask(taskId: "t-echo", program: "testprog", task: "echo", input: ["x": 1], dir: "", resumable: false) }
    wait("echo result") { result("t-echo") != nil }
    XCTAssertEqual(result("t-echo")?.data["output"]?["echo"]?["x"]?.int, 1)
    _ = try queue.sync { try manager.startTask(taskId: "t-wait", program: "testprog", task: "wait", input: [:], dir: "", resumable: false) }
    usleep(500_000)
    try queue.sync { try manager.stopTask(taskId: "t-wait", reason: .stopOn, grace: 5) }
    wait("wait result") { result("t-wait") != nil }
    XCTAssertEqual(result("t-wait")?.data["status"]?.string, "ok")
    XCTAssertEqual(result("t-wait")?.data["output"]?["stopReason"]?.string, "stopOn")
  }

  func testResumableTaskSurvivesAProgramCrash() throws {
    enable()
    wait("running") { status()["state"]?.string == "running" }
    _ = try queue.sync { try manager.startTask(taskId: "t-res", program: "testprog", task: "wait", input: [:], dir: "", resumable: true) }
    usleep(600_000)
    let pid = status()["pid"]?.int ?? 0
    XCTAssertGreaterThan(pid, 0)
    kill(Int32(pid), SIGKILL)
    wait("restarted") { (status()["pid"]?.int ?? pid) != pid && status()["state"]?.string == "running" }
    usleep(600_000)
    try queue.sync { try manager.stopTask(taskId: "t-res", reason: .stopOn, grace: 5) }
    wait("resumed result") { result("t-res") != nil }
    XCTAssertEqual(result("t-res")?.data["output"]?["resumed"]?.bool, true)
    XCTAssertEqual(result("t-res")?.data["output"]?["starts"]?.int, 2)
  }

  func testNonResumableTaskFailsWhenTheProgramCrashes() throws {
    enable()
    wait("running") { status()["state"]?.string == "running" }
    _ = try queue.sync { try manager.startTask(taskId: "t-crash", program: "testprog", task: "crash", input: [:], dir: "", resumable: false) }
    wait("error result") { result("t-crash") != nil }
    XCTAssertEqual(result("t-crash")?.data["status"]?.string, "error")
    wait("restarted after crash") { status()["state"]?.string == "running" }
  }

  func testInstalledReplacementResumesSameTaskAndReportsLoadedVersion() throws {
    enable()
    wait("running") { status()["state"]?.string == "running" }
    let pid = status()["pid"]?.int
    let dir = HelperPaths(dshHome: home).programsDir.appendingPathComponent("testprog")
    let manifestURL = dir.appendingPathComponent("manifest.json")
    let manifest = try JSON.parse(Data(contentsOf: manifestURL)).merging(["version": "9.0.0"])
    try Data(manifest.serialized().utf8).write(to: manifestURL, options: .atomic)
    queue.sync { manager.rescan() }
    XCTAssertEqual(status()["pid"]?.int, pid, "metadata-only changes must not restart the process")
    XCTAssertEqual(status()["version"]?.string, "0.0.1", "report the executable handshake, not its replacement manifest")
    XCTAssertEqual(status()["installedVersion"]?.string, "9.0.0")
    let taskDir = home.appendingPathComponent("capture")
    _ = try queue.sync { try manager.startTask(taskId: "same.capture", program: "testprog", task: "wait",
      input: ["correlationId": "same-meeting", "private": "not exposed"], dir: taskDir.path, resumable: true) }
    wait("checkpoint") { (try? AtomicFile.readJSON(JSON.self, from: taskDir.appendingPathComponent("checkpoint.json"))["starts"]?.int) == 1 }
    let listed = queue.sync { manager.taskList().array!.first! }
    XCTAssertEqual(listed["correlationId"]?.string, "same-meeting")
    XCTAssertNil(listed["input"])
    // A new executable wrapper exercises an actual byte change without modifying signed Mach-O bytes.
    let wrapper = "#!/bin/sh\nexec '\(Self.testprog.path)' \"$@\"\n"
    let executable = dir.appendingPathComponent("testprog")
    try Data(wrapper.utf8).write(to: executable, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    queue.sync { manager.rescan() }
    wait("replacement ready") { status()["state"]?.string == "running" && status()["pid"]?.int != pid }
    wait("resumed checkpoint") { (try? AtomicFile.readJSON(JSON.self, from: taskDir.appendingPathComponent("checkpoint.json"))["starts"]?.int) == 2 }
    XCTAssertNil(result("same.capture"), "updating must not publish a terminal result")
    let resumed = queue.sync { manager.taskList().array!.first! }
    XCTAssertEqual(resumed["taskId"]?.string, "same.capture")
    XCTAssertEqual(resumed["correlationId"]?.string, "same-meeting")
    XCTAssertEqual(resumed["deliveries"]?.int, 2)
    let replacementPid = status()["pid"]?.int
    queue.sync { manager.rescan() }
    XCTAssertEqual(status()["pid"]?.int, replacementPid)
    XCTAssertEqual(status()["state"]?.string, "running")
    try queue.sync { try manager.stopTask(taskId: "same.capture", reason: .stopOn, grace: 5) }
    wait("finished") { result("same.capture") != nil }
    XCTAssertEqual(result("same.capture")?.data["output"]?["starts"]?.int, 2)
  }

  func testProgramCommandsRoundTripAndUnavailableErrors() {
    let unavailable = expectation(description: "unavailable")
    queue.async {
      self.manager.command(program: "absent", command: ProgramCommand(requestId: "missing", correlationId: "meeting", action: "echo")) { result in
        XCTAssertEqual(result.error, "program_unavailable")
        unavailable.fulfill()
      }
    }
    wait(for: [unavailable], timeout: 2)
    enable()
    wait("running") { status()["state"]?.string == "running" }
    for action in ["echo", "invalid"] {
      let done = expectation(description: action)
      queue.async {
        self.manager.command(program: "testprog", command: ProgramCommand(requestId: UUID().uuidString, correlationId: "target", action: action)) { result in
          XCTAssertEqual(result.error, action == "echo" ? nil : "unknown_action")
          XCTAssertEqual(result.status["correlationId"]?.string, "target")
          done.fulfill()
        }
      }
      wait(for: [done], timeout: 5)
    }
  }

  func testHangingTaskIsKilledAfterGrace() throws {
    enable()
    wait("running") { status()["state"]?.string == "running" }
    _ = try queue.sync { try manager.startTask(taskId: "t-hang", program: "testprog", task: "hang", input: [:], dir: "", resumable: false) }
    usleep(300_000)
    try queue.sync { try manager.stopTask(taskId: "t-hang", reason: .timeout, grace: 1) }
    wait("timed_out result", timeout: 15) { result("t-hang") != nil }
    XCTAssertEqual(result("t-hang")?.data["status"]?.string, "timed_out")
  }

  func testCrashLoopIsDisabledAfterRepeatedFailures() {
    enable(config: ["crashOnStart": true])
    wait("failed", timeout: 20) { status()["state"]?.string == "failed" }
    XCTAssertTrue(status()["lastError"]?.string?.contains("disabled after") == true)
  }

  func testStalledLoopIsKilled() {
    enable(config: ["stallWatch": true])
    wait("stall detected", timeout: 20) { (status()["restarts"]?.int ?? 0) >= 1 }
  }
}

final class MenuCaptureSnapshotTests: XCTestCase {
  func testOnlyReadsMatchingCaptureAndReflectsRevisionsAndGaps() throws {
    let root = tempHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let other = root.appendingPathComponent("other", isDirectory: true)
    let selected = root.appendingPathComponent("selected", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
    func write(_ dir: URL, _ name: String, _ value: JSON) throws {
      try Data(value.serialized().utf8).write(to: dir.appendingPathComponent(name))
    }
    try write(other, "checkpoint.json", ["capture": ["assembler": ["lines": [["text": "other meeting"]]]]])
    try write(selected, "checkpoint.json", ["capture": ["assembler": ["lines": [["text": "first version"]]]]])
    try write(selected, "status.json", ["openGap": "captions_off"])
    let tasks: [JSON] = [
      ["program": "teams", "task": "captureCaptions", "taskId": "other.capture", "dir": .string(other.path)],
      ["program": "teams", "task": "captureCaptions", "taskId": "current.capture", "dir": .string(selected.path)],
    ]
    XCTAssertTrue(MenuCaptureSnapshot.read(tasks: tasks, runId: "current", correlationId: "new-meeting").capture.isNull)
    XCTAssertFalse(MenuCaptureSnapshot.read(tasks: tasks, runId: "current", correlationId: "same-meeting", runCorrelationId: "same-meeting").capture.isNull)
    let first = MenuCaptureSnapshot.read(tasks: tasks, runId: "current")
    let actualTaskShape = tasks.map { $0.merging(["correlationId": "same-meeting"]) }
    let withoutDesktopCorrelation = MenuCaptureSnapshot.read(tasks: actualTaskShape, runId: "current", correlationId: "same-meeting")
    XCTAssertEqual(withoutDesktopCorrelation.checkpoint["capture"]?["assembler"]?["lines"]?[0]?["text"]?.string, "first version")
    XCTAssertTrue(MenuCaptureSnapshot.read(tasks: actualTaskShape, runId: "current", correlationId: "new-meeting", runCorrelationId: "new-meeting").capture.isNull)
    XCTAssertEqual(first.checkpoint["capture"]?["assembler"]?["lines"]?[0]?["text"]?.string, "first version")
    XCTAssertEqual(first.status["openGap"]?.string, "captions_off")
    try write(selected, "checkpoint.json", ["capture": ["assembler": ["lines": [["text": "revised"]]]]])
    try write(selected, "status.json", ["openGap": .null])
    let revised = MenuCaptureSnapshot.read(tasks: tasks, runId: "current")
    XCTAssertEqual(revised.checkpoint["capture"]?["assembler"]?["lines"]?[0]?["text"]?.string, "revised")
    XCTAssertTrue(revised.status["openGap"]?.isNull == true)
    XCTAssertTrue(MenuCaptureSnapshot.read(tasks: tasks, runId: "missing").checkpoint.isNull)
    XCTAssertTrue(MenuCaptureSnapshot.read(tasks: tasks, runId: nil).capture.isNull)
    try Data(repeating: 0x20, count: 16_385).write(to: selected.appendingPathComponent("status.json"))
    XCTAssertTrue(MenuCaptureSnapshot.read(tasks: tasks, runId: "current").status.isNull)
  }
}
