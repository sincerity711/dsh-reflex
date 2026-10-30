import AppKit
import SwiftUI
import XCTest
import ReflexKit
@testable import ReflexHelper

final class MenuPanelTests: XCTestCase {
  @MainActor func testCaptureStatisticsUseThisRecordAndFullTranscript() throws {
    let start = try XCTUnwrap(ISO8601.parse("2026-10-29T08:16:07Z"))
    let captions: [JSON] = (0..<75).map { ["text": JSON("Line \($0)")] }
    let snapshot: JSON = ["locale": "zh-CN", "programs": [["id": "teams", "state": "running", "status": ["meeting": "in_meeting", "correlationId": "current", "since": JSON(start.addingTimeInterval(-3600))]]],
      "desktop": ["runId": "current"], "capture": ["taskId": "current.capture", "correlationId": "current", "startedAt": JSON(start.addingTimeInterval(-1))],
      "checkpoint": ["capture": ["startedAt": JSON(start), "assembler": ["lines": .array(captions)],
        "participants": ["state": "partial", "observedNames": ["Alex", "Sam"], "snapshots": [["reportedCount": 32, "names": ["Alex", "Sam"]]]]]]]
    let panel = MenuPanel(model: MenuModel(snapshot: snapshot))
    XCTAssertEqual(panel.captureStartedAt, start)
    XCTAssertEqual(panel.captureDuration(at: start.addingTimeInterval(3661)), "01:01:01")
    XCTAssertEqual(panel.captureDuration(at: start.addingTimeInterval(-1)), "00:00")
    XCTAssertEqual(panel.captureStartLabel(at: start, timeZone: TimeZone(identifier: "Asia/Shanghai")!), "16:16:07")
    XCTAssertEqual(panel.captureStartLabel(at: start.addingTimeInterval(86400), timeZone: TimeZone(identifier: "Asia/Shanghai")!), "10/29 16:16")
    XCTAssertEqual(panel.capturedLineCount, 75)
    XCTAssertEqual(panel.lines.count, 30)
    XCTAssertEqual(panel.participantNames, ["Alex", "Sam"])
    XCTAssertEqual(panel.participantCountLabel, "32 人 · 已读 2")
    let english = MenuPanel(model: MenuModel(snapshot: snapshot.merging(["locale": "en"])))
    XCTAssertEqual(english.participantCountLabel, "32 people · 2 read")
    let stale = MenuPanel(model: MenuModel(snapshot: snapshot.merging(["capture": ["taskId": "old.capture", "correlationId": "old"]])))
    XCTAssertNil(stale.captureStartedAt)
    XCTAssertNil(stale.capturedLineCount)
    XCTAssertTrue(stale.participantNames.isEmpty)
  }

  @MainActor func testBackgroundButtonLanguagesAndRestoreWithoutLiveMeeting() {
    let snapshot: JSON = ["axTrusted": true, "locale": "zh-CN", "programs": [
      ["id": "teams", "state": "running", "status": ["meeting": "in_meeting", "correlationId": "one"]]]]
    let foreground = MenuPanel(model: MenuModel(snapshot: snapshot))
    XCTAssertTrue(foreground.canPark)
    XCTAssertFalse(foreground.backgroundActive)
    XCTAssertEqual(foreground.backgroundLabel, "移入后台监控")
    let parked = MenuPanel(model: MenuModel(snapshot: ["locale": "en", "backgroundMeeting": ["active": true, "correlationId": "one"]]))
    XCTAssertTrue(parked.backgroundActive)
    XCTAssertFalse(parked.canPark)
    XCTAssertEqual(parked.backgroundLabel, "Bring Teams back")
    XCTAssertGreaterThan(NSHostingView(rootView: parked).fittingSize.height, 0)
  }

  @MainActor func testConfirmationControlsCountdownAndLanguages() {
    let deadline = Date(timeIntervalSince1970: 1_800_000_120)
    let state: JSON = ["id": "teams", "state": "running", "status": ["meeting": "leave_pending", "commandsSupported": true,
      "correlationId": "target", "episode": 2, "deadline": JSON(deadline)]]
    let snapshot: JSON = ["connected": true, "axTrusted": true, "locale": "zh-CN", "programs": [state]]
    let panel = MenuPanel(model: MenuModel(snapshot: snapshot))
    XCTAssertTrue(panel.waiting)
    XCTAssertEqual(panel.remaining(at: deadline.addingTimeInterval(-119.1)), 120)
    XCTAssertEqual(panel.remaining(at: deadline.addingTimeInterval(1)), 0)
    XCTAssertTrue(panel.canCommand)
    XCTAssertTrue(panel.waitingText.contains("暂时无法检测会议"))
    let english = MenuPanel(model: MenuModel(snapshot: snapshot.merging(["locale": "en"])))
    XCTAssertTrue(english.waiting)
    XCTAssertTrue(english.waitingText.contains("Restore the Teams meeting window"))
    let normal = state.merging(["status": ["meeting": "in_meeting", "commandsSupported": true, "correlationId": "target"]])
    let active = MenuPanel(model: MenuModel(snapshot: snapshot.merging(["programs": [normal]])))
    XCTAssertFalse(active.waiting)
    XCTAssertTrue(active.canCommand)
    XCTAssertFalse(MenuPanel(model: MenuModel(snapshot: snapshot.merging(["programs": [state.merging(["state": "stopped"])]]))).canCommand)
    XCTAssertGreaterThan(NSHostingView(rootView: panel).fittingSize.height, 0)
  }

  @MainActor func testCurrentTitleAndTranscriptNeverFallBackToAnOldMeeting() {
    func panel(_ snapshot: JSON) -> MenuPanel { MenuPanel(model: MenuModel(snapshot: snapshot)) }
    let current: JSON = ["id": "teams", "state": "running", "status": ["meeting": "in_meeting", "correlationId": "current", "title": "当前会议"]]
    let active: JSON = ["connected": true, "axTrusted": true, "locale": "zh-CN", "programs": [current], "desktop": ["runId": "run", "correlationId": "current", "title": "开始时的标题", "status": "running", "step": "capture"], "capture": ["taskId": "run.capture", "state": "running"], "checkpoint": ["capture": ["assembler": ["lines": [["speaker": "Alex", "text": "测试字幕"]]]]]]
    let capturing = panel(active)
    XCTAssertEqual(capturing.meetingTitle, "当前会议")
    XCTAssertEqual(capturing.lines.first?["text"]?.string, "测试字幕")
    XCTAssertTrue(capturing.matchingCapture)
    let legacyDesktop = active.merging(["desktop": ["runId": "run", "status": "running", "step": "capture"],
      "capture": ["taskId": "run.capture", "state": "running", "correlationId": "current"]])
    let realTaskShape = panel(legacyDesktop)
    XCTAssertTrue(realTaskShape.canPark)
    XCTAssertTrue(realTaskShape.matchingCapture)
    XCTAssertEqual(realTaskShape.lines.first?["text"]?.string, "测试字幕")
    XCTAssertTrue(panel(legacyDesktop.merging(["capture": ["taskId": "run.capture", "correlationId": "old"]])).lines.isEmpty)
    XCTAssertFalse(panel(active.merging(["capture": ["taskId": "another.capture", "state": "running"]])).matchingCapture)
    for state in ["idle", "suppressed"] {
      let ended = panel(active.merging(["programs": [current.merging(["status": ["meeting": JSON(state)]])]]))
      XCTAssertEqual(ended.meetingTitle, "当前没有会议")
      XCTAssertTrue(ended.lines.isEmpty)
      XCTAssertFalse(ended.canCommand)
    }
    let unknown = panel(active.merging(["programs": [], "locale": "en"]))
    XCTAssertEqual(unknown.meetingTitle, "No current meeting")
    XCTAssertTrue(unknown.lines.isEmpty)
    let next = panel(active.merging(["programs": [current.merging(["status": ["meeting": "in_meeting", "correlationId": "next"]])]]))
    XCTAssertEqual(next.meetingTitle, "Teams 会议")
    XCTAssertTrue(next.lines.isEmpty)
    let waiting = panel(active.merging(["programs": [current.merging(["status": ["meeting": "leave_pending", "correlationId": "current", "title": "当前会议"]])]]))
    XCTAssertEqual(waiting.meetingTitle, "当前会议")
    XCTAssertTrue(waiting.matchingCapture)
    let model = MenuModel(snapshot: active)
    model.snapshot = active.merging(["programs": [current.merging(["status": ["meeting": "idle"]])]])
    XCTAssertEqual(MenuPanel(model: model).meetingTitle, "当前没有会议")
    let view = NSHostingView(rootView: capturing)
    let size = view.fittingSize
    XCTAssertEqual(size.width, 500)
    XCTAssertGreaterThan(size.height, 380)
  }

  @MainActor func testReattachAndEndConfirmationAreSeparateFromBackgroundAction() {
    let stopped: JSON = ["programs": [["id": "teams", "state": "running", "status": [
      "meeting": "suppressed", "attachSupported": true, "attachCorrelationId": "old"]]], "locale": "zh-CN"]
    let panel = MenuPanel(model: MenuModel(snapshot: stopped))
    XCTAssertTrue(panel.canAttach)
    XCTAssertFalse(panel.canCommand)
    XCTAssertFalse(panel.canPark)
    XCTAssertEqual(panel.meetingTitle, "记录已停止")
    XCTAssertTrue(panel.lines.isEmpty)
    XCTAssertGreaterThan(NSHostingView(rootView: panel).fittingSize.height, 100)
    let model = MenuModel(snapshot: .null)
    let target: JSON = ["correlationId": "current"]
    model.requestEnd(target)
    XCTAssertEqual(model.endConfirmation?["correlationId"]?.string, "current")
    XCTAssertFalse(model.commandPending, "opening confirmation must not send an end request")
    model.cancelEnd()
    XCTAssertNil(model.endConfirmation)
    XCTAssertFalse(model.commandPending)
  }

  @MainActor func testGlassPanelPreviewWhenRequested() throws {
    guard let dir = ProcessInfo.processInfo.environment["REFLEX_MENU_PREVIEW_DIR"] else { return }
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for locale in ["en", "zh-CN"] {
      for dark in [false, true] {
      for mode in ["active", "confirm", "stopped", "idle", "offline"] {
        let status: JSON = ["idle", "offline"].contains(mode) ? ["meeting": "idle"] : mode == "stopped" ? ["meeting": "suppressed", "attachSupported": true, "attachCorrelationId": "preview"] :
          ["meeting": "in_meeting", "commandsSupported": true, "correlationId": "preview", "title": locale == "en" ? "Product design review" : "产品设计评审"]
        let model = MenuModel(snapshot: ["locale": JSON(locale), "connected": JSON(mode != "offline"), "axTrusted": true,
          "programs": [["id": "teams", "state": "running", "status": status]],
          "desktop": ["runId": "preview"], "capture": ["taskId": "preview.capture", "correlationId": "preview", "startedAt": JSON(Date().addingTimeInterval(-1210))],
          "checkpoint": ["capture": ["participants": ["state": "available", "observedNames": ["Alex", "Sam"], "snapshots": [["reportedCount": 2]]], "assembler": ["lines": [
            ["speaker": "Alex", "text": locale == "en" ? "Let's keep the meeting controls clear and the captions easy to read." : "我们把会议操作做得清楚一点，让字幕更容易阅读。"],
            ["speaker": "Sam", "text": locale == "en" ? "Teams can move to the background while this transcript stays here." : "Teams 可以移到后台，实时字幕继续显示在这里。"]]]]]])
        if mode == "confirm" { model.requestEnd(status) }
        let view = NSHostingView(rootView: MenuPanel(model: model)
          .background(dark ? Color(white: 0.12) : Color.white)
          .environment(\.colorScheme, dark ? .dark : .light))
        let size = view.fittingSize
        XCTAssertEqual(size.width, 500)
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(locale)-\(mode)-\(dark ? "dark" : "light").png"))
      }
      }
    }
  }
}
