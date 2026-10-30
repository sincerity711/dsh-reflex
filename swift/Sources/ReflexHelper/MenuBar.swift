import AppKit
import SwiftUI
import ReflexHelperCore
import ReflexKit

/// Native Liquid Glass on Tahoe; keep the same readable material on older macOS releases.
private struct ReflexGlassSurface: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    #if compiler(>=6.2)
    if #available(macOS 26.0, *) {
      content.background {
        RoundedRectangle(cornerRadius: 16).fill(.clear)
          .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
      }
    } else {
      fallback(content)
    }
    #else
    fallback(content)
    #endif
  }

  private func fallback(_ content: Content) -> some View {
    content.background(.ultraThinMaterial)
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
  }
}

/// Displays only a bounded, in-memory view of the existing capture checkpoint.
final class MenuModel: ObservableObject {
  @Published var snapshot: JSON = .null
  @Published var commandPending = false
  @Published var commandError: String?
  @Published var endConfirmation: JSON?
  @Published var backgroundPending = false
  @Published var backgroundError: String?
  private var retryCommand: ProgramCommand?
  private var notifiedEpisode: String?

  func requestEnd(_ meeting: JSON) { endConfirmation = meeting }
  func cancelEnd() { endConfirmation = nil }
  func confirmEnd() {
    guard let target = endConfirmation else { return }
    endConfirmation = nil
    command("end", meeting: target)
  }

  func attach(_ meeting: JSON) {
    guard let id = meeting["attachCorrelationId"]?.string else { return }
    command("attach", meeting: ["correlationId": .string(id)])
  }

  func background(_ action: String, correlation: String?) {
    guard !backgroundPending, let service else { return }
    backgroundPending = true
    backgroundError = nil
    service.backgroundMeetingCommand(action, correlation: correlation) { [weak self] error in
      self?.backgroundError = error
      // Refresh before allowing another click; the button must reflect the completed operation.
      service.menuSnapshot { value in
        self?.snapshot = value
        self?.backgroundPending = false
      }
    }
  }

  func command(_ action: String, meeting: JSON) {
    guard !commandPending, let id = meeting["correlationId"]?.string else { return }
    let cmd: ProgramCommand
    if let retry = retryCommand, retry.action == action, retry.correlationId == id, retry.episode == meeting["episode"]?.int,
       Date().timeIntervalSince(retry.issuedAt) <= 60 { cmd = retry }
    else { cmd = ProgramCommand(requestId: UUID().uuidString, correlationId: id, action: action, episode: meeting["episode"]?.int) }
    commandPending = true
    commandError = nil
    retryCommand = cmd
    guard let service else { commandPending = false; commandError = "program_unavailable"; return }
    service.meetingCommand(cmd) { [weak self] result in
      self?.commandPending = false
      self?.commandError = result.error
      if result.error == nil { self?.retryCommand = nil }
      self?.refresh()
    }
  }

  private func notice(_ snapshot: JSON) {
    guard let status = snapshot["programs"]?.array?.first(where: { $0["id"]?.string == "teams" })?["status"],
          status["meeting"]?.string == "leave_pending", let id = status["correlationId"]?.string,
          let episode = status["episode"]?.int else { return }
    let key = "\(id):\(episode)"
    guard notifiedEpisode != key else { return }
    notifiedEpisode = key
    // Persist the episode token, not meeting text, so helper restarts don't repeat a notice.
    guard UserDefaults.standard.string(forKey: "reflex.meetingNotice") != key else { return }
    UserDefaults.standard.set(key, forKey: "reflex.meetingNotice")
    let zh = (snapshot["locale"]?.string ?? "en").hasPrefix("zh")
    let message = zh ? "暂时无法检测会议，请恢复 Teams 会议窗口；如果会议已结束，请确认。" : "Meeting temporarily undetected. Restore the Teams meeting window, or confirm that the meeting has ended."
    // Same local notification mechanism as the existing notify builtin; no focus change.
    DispatchQueue.global().async {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-e", "on run argv", "-e", "display notification (item 1 of argv) with title \"Reflex\"", "-e", "end run", message]
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do { try process.run(); process.waitUntilExit() } catch {}
    }
  }
  var onUpdate: ((JSON) -> Void)?
  let service: HelperService?
  private var timer: Timer?
  init(service: HelperService) {
    self.service = service
    refresh()
    let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }
  init(snapshot: JSON) { service = nil; self.snapshot = snapshot }
  func refresh() { service?.menuSnapshot { [weak self] value in self?.snapshot = value; self?.notice(value); self?.onUpdate?(value) } }
}

struct MenuPanel: View {
  @ObservedObject var model: MenuModel
  var s: JSON { model.snapshot }
  var zh: Bool { (s["locale"]?.string ?? "en").lowercased().hasPrefix("zh") }
  func t(_ english: String, _ chinese: String) -> String { zh ? chinese : english }
  var connected: Bool { s["connected"]?.bool == true }
  var run: JSON { s["desktop"] ?? .null }
  var capture: JSON { s["capture"] ?? .null }
  var matchingCapture: Bool {
    guard hasCurrentMeeting, let correlation = meeting["correlationId"]?.string,
          let id = run["runId"]?.string, capture["taskId"]?.string == id + ".capture" else { return false }
    return (capture["correlationId"]?.string ?? capture["input"]?["correlationId"]?.string ?? run["correlationId"]?.string) == correlation
  }
  var gap: String? { s["captureStatus"]?["openGap"]?.string }
  var teams: JSON? { s["programs"]?.array?.first { $0["id"]?.string == "teams" } }
  var meeting: JSON { teams?["status"] ?? .null }
  var hasCurrentMeeting: Bool {
    teams?["state"]?.string == "running" && ["in_meeting", "leave_pending"].contains(meeting["meeting"]?.string ?? "")
  }
  var meetingTitle: String {
    guard hasCurrentMeeting else { return canAttach ? t("Recording stopped", "记录已停止") : t("No current meeting", "当前没有会议") }
    if let title = meeting["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
    // Only use saved metadata when it belongs to this exact meeting, never the previous run.
    if let id = meeting["correlationId"]?.string, run["correlationId"]?.string == id,
       let title = run["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
    return t("Teams meeting", "Teams 会议")
  }
  var waiting: Bool { hasCurrentMeeting && meeting["meeting"]?.string == "leave_pending" }
  var backgroundActive: Bool { s["backgroundMeeting"]?["active"]?.bool == true }
  var canPark: Bool {
    hasCurrentMeeting && s["axTrusted"]?.bool == true && meeting["correlationId"]?.string != nil
  }
  var backgroundLabel: String { backgroundActive ? t("Bring Teams back", "带回 Teams") : t("Move Teams to background", "移入后台监控") }
  var canCommand: Bool {
    hasCurrentMeeting && meeting["commandsSupported"]?.bool == true && meeting["correlationId"]?.string != nil
  }
  var canAttach: Bool {
    teams?["state"]?.string == "running" && meeting["meeting"]?.string == "suppressed"
      && meeting["attachSupported"]?.bool == true && meeting["attachCorrelationId"]?.string != nil
  }
  var waitingText: String { t("Meeting temporarily undetected. Restore the Teams meeting window, or confirm that the meeting has ended.", "暂时无法检测会议，请恢复 Teams 会议窗口；如果会议已结束，请确认。") }
  func remaining(at now: Date) -> Int? {
    guard let raw = meeting["deadline"]?.string, let date = ISO8601.parse(raw) else { return nil }
    return max(0, Int(ceil(date.timeIntervalSince(now))))
  }
  var lines: [JSON] { matchingCapture ? Array((s["checkpoint"]?["capture"]?["assembler"]?["lines"]?.array ?? []).suffix(30)) : [] }
  var captureStartedAt: Date? {
    guard matchingCapture else { return nil }
    for raw in [s["checkpoint"]?["capture"]?["startedAt"]?.string, capture["startedAt"]?.string] {
      if let raw, let date = ISO8601.parse(raw) { return date }
    }
    return nil
  }
  var capturedLineCount: Int? {
    guard matchingCapture else { return nil }
    return s["checkpoint"]?["capture"]?["assembler"]?["lines"]?.array?.count
  }
  func captureStartLabel(at now: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
    guard let start = captureStartedAt else { return "—" }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = calendar.isDate(start, inSameDayAs: now) ? "HH:mm:ss" : "MM/dd HH:mm"
    return formatter.string(from: start)
  }
  func captureDuration(at now: Date) -> String {
    guard let start = captureStartedAt else { return "—" }
    let seconds = Int(max(0, now.timeIntervalSince(start)))
    return seconds >= 3600 ? String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
      : String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
  var participantInfo: JSON { matchingCapture ? s["checkpoint"]?["capture"]?["participants"] ?? .null : .null }
  var participantNames: [String] { participantInfo["observedNames"]?.array?.compactMap(\.string) ?? [] }
  var participantCountLabel: String {
    let current = ["available", "partial"].contains(participantInfo["state"]?.string ?? "")
    if current, let latest = participantInfo["snapshots"]?.array?.last, let n = latest["reportedCount"]?.int {
      if participantInfo["state"]?.string == "partial" {
        let read = latest["names"]?.array?.count ?? 0
        return t("\(n) people · \(read) read", "\(n) 人 · 已读 \(read)")
      }
      return t("\(n) people", "\(n) 人")
    }
    return participantNames.isEmpty ? t("Not read yet", "尚未读取") : t("\(participantNames.count) names saved", "已存 \(participantNames.count) 个姓名")
  }
  func metric(_ label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 12, weight: .medium)).monospacedDigit()
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  var detail: String {
    switch gap {
    case "captions_off", "unreadable": return t("Turn on Teams live captions or make the meeting window visible.", "请打开 Teams 实时字幕，或让会议窗口保持可见。")
    case "window_frozen", "page_stalled": return t("Teams is not updating captions. Make the meeting window visible.", "Teams 字幕没有更新，请让会议窗口保持可见。")
    default: return t("Waiting for captions…", "等待字幕…")
    }
  }
  var showIdle: Bool { !hasCurrentMeeting && !canAttach }
  var idleReady: Bool {
    connected && s["axTrusted"]?.bool == true && teams?["enabled"]?.bool != false
      && teams?["installed"]?.bool != false && ["running", "idle"].contains(teams?["state"]?.string ?? "")
  }
  var idleTitle: String {
    if !connected { return t("Waiting for connection", "等待连接") }
    if s["axTrusted"]?.bool == false { return t("One step to get ready", "还差一步，即可开始") }
    if teams?["enabled"]?.bool == false { return t("Monitoring is paused", "会议监测已暂停") }
    if teams?["state"]?.string == "failed" || teams?["installed"]?.bool == false { return t("Monitoring needs attention", "会议监测需要恢复") }
    return idleReady ? t("Ready for your next meeting", "准备好，迎接下一场会议") : t("Getting ready", "正在准备")
  }
  var idleDetail: String {
    if !connected { return t("Reconnect DSH to keep your meeting records flowing.", "重新连接 DSH，即可继续处理会议记录。") }
    if s["axTrusted"]?.bool == false { return t("Allow Reflex Helper in macOS Accessibility settings to read Teams captions.", "在 macOS 辅助功能设置中允许 Reflex Helper，即可读取 Teams 字幕。") }
    if teams?["enabled"]?.bool == false { return t("Enable Teams monitoring in Reflex settings when you’re ready.", "在 Reflex 设置中开启 Teams 监测，即可继续。") }
    if teams?["installed"]?.bool == false { return t("Install the Teams program from Reflex to get started.", "在 Reflex 中安装 Teams 程序后即可开始。") }
    if teams?["state"]?.string == "failed" { return t("Restart Teams monitoring from Reflex settings.", "在 Reflex 设置中重启 Teams 监测。") }
    return idleReady ? t("Join a Teams meeting and turn on live captions.\nYour transcript will appear here.", "进入 Teams 会议并开启实时字幕，\n这里会自动开始记录。") : t("Your meeting controls will appear here shortly.", "会议操作就绪后会显示在这里。")
  }
  var idlePanel: some View {
    VStack(spacing: 0) {
      ZStack {
        Circle().fill(Color.accentColor.opacity(0.035)).frame(width: 98, height: 98)
        Circle().fill(LinearGradient(colors: [Color.accentColor.opacity(0.14), Color.accentColor.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing))
          .frame(width: 72, height: 72)
          .overlay(Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        Image(systemName: idleReady ? "waveform" : "pause")
          .font(.system(size: 28, weight: .light)).foregroundStyle(Color.accentColor)
      }.accessibilityHidden(true)
      Text(idleTitle).font(.system(size: 21, weight: .semibold)).multilineTextAlignment(.center).padding(.top, 16)
      Text(idleDetail).font(.system(size: 13)).lineSpacing(4).foregroundStyle(.secondary)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 360).padding(.top, 9)
    }.frame(maxWidth: .infinity).padding(.vertical, 22)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if showIdle {
        idlePanel
      } else {
      VStack(alignment: .leading, spacing: 12) {
        Text(meetingTitle).font(.system(size: 21, weight: .semibold)).lineLimit(2)
          .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        if matchingCapture {
          TimelineView(.periodic(from: .now, by: 1)) { timeline in
            HStack(spacing: 12) {
              metric(t("Capture started", "开始采集"), value: captureStartLabel(at: timeline.date))
              metric(t("Record elapsed", "记录时长"), value: captureDuration(at: timeline.date))
              metric(t("Captions saved", "已存字幕"), value: capturedLineCount.map { t("\($0) lines", "\($0) 条") } ?? "—")
            }
          }.help(t("For this Reflex record, including periods when captions were unavailable. Full-record count, not just the visible lines.", "按本段 Reflex 记录计算，时长包含字幕暂不可用的时段；条数为整段记录总数。"))
        }
      }.padding(.bottom, 18)
      }
      VStack(alignment: .leading, spacing: 14) {
        if waiting {
          Text(waitingText).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
          TimelineView(.periodic(from: .now, by: 1)) { timeline in
            if let seconds = remaining(at: timeline.date) {
              Text(t("Recording ends automatically in \(seconds)s if detection does not recover.", "若仍无法检测，将在 \(seconds) 秒后自动结束记录。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
          }
        }
        if backgroundActive || canPark {
          Button {
            model.background(backgroundActive ? "bringBack" : "park", correlation:
              backgroundActive ? s["backgroundMeeting"]?["correlationId"]?.string : meeting["correlationId"]?.string)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: backgroundActive ? "arrow.up.forward.app" : "macwindow")
              Text(backgroundLabel).fontWeight(.semibold)
              Spacer()
              if model.backgroundPending { ProgressView().controlSize(.small) }
              else { Image(systemName: backgroundActive ? "arrow.down.right" : "arrow.up.left") }
            }.font(.system(size: 13)).padding(13).contentShape(Rectangle())
          }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            .disabled(model.backgroundPending)
              .help(backgroundActive
                    ? t("Restores Teams and closes the background display.", "带回 Teams 后自动关闭后台屏幕。")
                    : t("Moves Teams to the upper-left background display.", "将 Teams 移到左上角的后台屏幕。"))
        }
        if canAttach {
          Text(t("Teams can stay in the call. Start a new record to capture its live captions.", "Teams 会议可以继续。重新接入后会开始一段新记录，之前的字幕仍保留。"))
            .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          Button { model.attach(meeting) } label: {
            HStack {
              Label(t("Capture current meeting", "采集当前会议"), systemImage: "captions.bubble")
              Spacer()
              if model.commandPending { ProgressView().controlSize(.small) }
              else { Image(systemName: "arrow.right") }
            }.font(.system(size: 13, weight: .semibold)).padding(13).contentShape(Rectangle())
          }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            .disabled(model.commandPending)
        }
        if let error = model.backgroundError ?? s["backgroundMeeting"]?["error"]?.string {
          Text(error == "noMeetingWindow" || error == "multipleMeetings"
               ? t("Open one Teams meeting window in normal window mode, then retry.", "请展开一个 Teams 会议窗口并退出全屏，再重试。")
               : t("Window move was not confirmed. Retry bringing Teams back before closing the background display.", "窗口移动尚未确认；如已移入后台，请重试带回 Teams。"))
            .font(.system(size: 11)).foregroundStyle(.orange)
        }
        if let error = model.commandError {
          Text(error == "meeting_not_detected"
               ? t("Restore the Teams meeting window, then try again.", "请先展开 Teams 会议窗口，再尝试接入。")
               : t("Operation not confirmed. Refresh or retry.", "操作尚未确认，请刷新或重试。"))
            .font(.system(size: 12)).foregroundStyle(.red)
        }
        if matchingCapture {
          DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
              Text(t("Names observed in the Teams participant panel; they may include people no longer present. Observation times are not verified join or leave times.", "以下是从 Teams 参会人面板读到的姓名，可能包含已离开的人；观测时间不代表实际加入或离开时间。"))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              if participantInfo["state"]?.string != "available" {
                Text(t("Open the Teams participant panel and expand See more to read the remaining names.", "打开 Teams 参会人面板并展开“查看更多 / See more”，可读取其余姓名。"))
                  .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              }
              if !participantNames.isEmpty {
                ScrollView {
                  VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(participantNames.enumerated()), id: \.offset) { _, name in
                      Text(name).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                  }
                }.frame(maxHeight: 120)
              }
            }.padding(.top, 8)
          } label: {
            HStack {
              Text(t("Participants", "参会人"))
              Spacer()
              Text(participantCountLabel).foregroundStyle(.secondary).monospacedDigit()
            }.font(.system(size: 12))
          }
          if lines.isEmpty || gap != nil {
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }
          if !lines.isEmpty {
            Text(t("LIVE CAPTIONS", "实时字幕")).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
              ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                  ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 5) {
                      if let speaker = line["speaker"]?.string, !speaker.isEmpty { Text(speaker).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary) }
                      Text(line["text"]?.string ?? "").font(.system(size: 15)).lineSpacing(4).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                  }
                  Color.clear.frame(height: 1).id("transcript-bottom")
                }.padding(14)
              }.frame(height: 400)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
                .task(id: lines) {
                  await Task.yield() // Scroll only after SwiftUI has laid out the revised caption.
                  guard !Task.isCancelled else { return }
                  proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
            }
          }
        } else if !showIdle && !connected {
          Text(t("Reconnect DSH to process meeting records.", "重新连接 DSH 后才能处理会议记录。"))
            .font(.system(size: 12)).foregroundStyle(.secondary)
        } else if !showIdle && s["axTrusted"]?.bool == false {
          Text(t("Allow Reflex Helper in macOS Accessibility settings.", "请在 macOS 辅助功能设置中允许 Reflex Helper。"))
            .font(.system(size: 12)).foregroundStyle(.secondary)
        } else if !showIdle && teams?["enabled"]?.bool == false {
          Text(t("Enable Teams monitoring in Reflex settings.", "请在 Reflex 中启用 Teams 监督。"))
            .font(.system(size: 12)).foregroundStyle(.secondary)
        } else if !showIdle && teams?["state"]?.string == "failed" {
          Text(t("Restart the Teams program from Reflex.", "请从 Reflex 重启 Teams 程序。"))
            .font(.system(size: 12)).foregroundStyle(.secondary)
        } else if hasCurrentMeeting {
          Text(t("Waiting for captions…", "等待字幕…"))
            .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        if canCommand {
          Divider().padding(.top, 2)
          if let target = model.endConfirmation, target["correlationId"]?.string == meeting["correlationId"]?.string {
            VStack(alignment: .leading, spacing: 10) {
              Text(t("Finish this record?", "结束这段记录？")).font(.system(size: 13, weight: .semibold))
              Text(t("Reflex will save the captions and generate notes. Your Teams call will continue.", "Reflex 会保存字幕并生成纪要，Teams 通话继续。"))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
              HStack {
                Button(t("Keep recording", "继续采集")) { model.cancelEnd() }
                Spacer()
                Button(t("Finish & summarize", "结束并生成纪要"), role: .destructive) { model.confirmEnd() }
              }.controlSize(.small).disabled(model.commandPending)
            }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
          } else {
            HStack {
              if waiting { Button(t("Still in meeting", "仍在开会")) { model.command("continue", meeting: meeting) } }
              if model.commandPending { ProgressView().controlSize(.small) }
              Spacer()
              Button(t("Finish recording…", "结束记录…")) { model.requestEnd(meeting) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(t("Save this record and generate notes.", "保存这段记录并生成纪要。"))
            }.font(.system(size: 12)).disabled(model.commandPending)
          }
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.padding(20).frame(width: 500)
      .modifier(ReflexGlassSurface())
      .onChange(of: meeting["correlationId"]?.string) { _ in model.cancelEnd() }
  }
}

final class MenuBarController: NSObject {
  private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private let model: MenuModel
  init(service: HelperService) {
    model = MenuModel(service: service)
    super.init()
    popover.behavior = .transient
    popover.contentViewController = NSHostingController(rootView: MenuPanel(model: model))
    item.button?.image = NSImage(systemSymbolName: "waveform.path", accessibilityDescription: "Reflex")
    item.button?.target = self
    item.button?.action = #selector(toggle)
    model.onUpdate = { [weak self] snapshot in
      let connected = snapshot["connected"]?.bool == true
      let gap = snapshot["captureStatus"]?["openGap"]?.string != nil || snapshot["programs"]?.array?.first(where: { $0["id"]?.string == "teams" })?["status"]?["meeting"]?.string == "leave_pending"
      let capturing = snapshot["capture"]?["state"]?.string == "running"
      let symbol = !connected || gap ? "exclamationmark.circle" : capturing ? "waveform.circle.fill" : "waveform.path"
      self?.item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Reflex")
    }
  }
  @objc private func toggle() {
    guard let button = item.button else { return }
    if popover.isShown { popover.performClose(nil) }
    else { model.refresh(); popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
  }
}
