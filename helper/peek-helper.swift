// peek-helper: read-only macOS window inspector used by the peek MCP server.
// It ships inside "Agent Peek.app" and is launched through LaunchServices, so macOS asks for permissions on behalf of Agent Peek.
//   peek-helper status                 -> which permissions Agent Peek has
//   peek-helper request-access         -> shows macOS's Accessibility and Screen Recording prompts and adds Agent Peek to those lists
//   peek-helper list                 -> JSON of app windows (visible, minimized, other Spaces), front-to-back
//   peek-helper text <windowId> [maxChars] -> JSON with the window's accessibility text, URL, document path
//   peek-helper shot <windowId> <out.png>  -> window screenshot
//   peek-helper ocr <image.png>          -> text recognized in an image (fallback for windows on other Spaces)
//   peek-helper pdf <path> [maxChars]     -> text of a PDF
//   peek-helper clipboard <imageOut.png>   -> clipboard text, URLs, files, and image (if any)
//   peek-helper messages-chats [limit]     -> recent iMessage/SMS chats (needs Full Disk Access)
//   peek-helper messages-read <chatId> [limit] [beforeUnix]
//   peek-helper messages-search <query> [limit]
import AppKit
import ApplicationServices
import PDFKit
import Foundation
import SQLite3
import Vision

func emit(_ obj: Any) {
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

func fail(_ msg: String) -> Never {
    emit(["error": msg])
    exit(1)
}

struct Win {
    let id: Int
    let pid: pid_t
    let app: String
    let title: String
    let bounds: CGRect
    let onScreen: Bool
}

// All normal app windows, including minimized ones and ones on other Spaces.
// Off-screen windows are only kept when they have a title, which filters out hidden helper windows.
func windows() -> [Win] {
    guard let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    var out: [Win] = []
    for w in info {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let id = w[kCGWindowNumber as String] as? Int,
              let pid = w[kCGWindowOwnerPID as String] as? Int,
              let app = w[kCGWindowOwnerName as String] as? String,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        if rect.width < 80 || rect.height < 80 { continue }
        let title = w[kCGWindowName as String] as? String ?? ""
        let onScreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
        if !onScreen && title.isEmpty { continue }
        out.append(Win(id: id, pid: pid_t(pid), app: app, title: title, bounds: rect, onScreen: onScreen))
    }
    return out
}

// MARK: - Accessibility helpers

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func str(_ el: AXUIElement, _ name: String) -> String? {
    if let s = attr(el, name) as? String { return s }
    if let u = attr(el, name) as? URL { return u.absoluteString }
    return nil
}

func frame(_ el: AXUIElement) -> CGRect? {
    guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return CGRect(origin: pt, size: sz)
}

// Chromium/Electron apps only build their accessibility tree when asked.
func enableWebAccessibility(_ app: AXUIElement) {
    AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
}

func axWindow(for w: Win, readContent: Bool = true) -> AXUIElement? {
    let app = AXUIElementCreateApplication(w.pid)
    AXUIElementSetMessagingTimeout(app, 2.0)
    if readContent { enableWebAccessibility(app) }
    guard let wins = attr(app, kAXWindowsAttribute) as? [AXUIElement], !wins.isEmpty else { return nil }
    // Prefer an exact frame match, then a title match, then the first window.
    if let m = wins.first(where: { frame($0).map { abs($0.minX - w.bounds.minX) < 4 && abs($0.minY - w.bounds.minY) < 4 && abs($0.width - w.bounds.width) < 4 } ?? false }) {
        return m
    }
    if !w.title.isEmpty, let m = wins.first(where: { str($0, kAXTitleAttribute) == w.title }) { return m }
    // Guessing is only safe for visible windows; an off-screen guess could read the wrong window.
    return w.onScreen ? wins.first : nil
}

func state(of w: Win) -> String {
    if w.onScreen { return "visible" }
    if NSRunningApplication(processIdentifier: w.pid)?.isHidden == true { return "hidden" }
    if let axw = axWindow(for: w, readContent: false), (attr(axw, kAXMinimizedAttribute) as? Bool) == true { return "minimized" }
    return "otherSpace"
}

struct Collector {
    var lines: [String] = []
    var chars = 0
    var nodes = 0
    var truncated = false
    var webURL: String?
    let maxChars: Int
    let deadline: Date

    mutating func add(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, lines.last != t else { return }
        if chars + t.count > maxChars { truncated = true; return }
        lines.append(t)
        chars += t.count + 1
    }

    mutating func walk(_ el: AXUIElement, depth: Int) {
        if truncated || depth > 80 || Date() > deadline { truncated = true; return }
        nodes += 1
        let role = str(el, kAXRoleAttribute) ?? ""
        switch role {
        case "AXWebArea":
            if webURL == nil { webURL = str(el, "AXURL") }
        case "AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXCell":
            if let v = str(el, kAXValueAttribute) { add(v) } else if let d = str(el, kAXDescriptionAttribute) { add(d) }
        case "AXLink":
            let text = str(el, kAXTitleAttribute) ?? str(el, kAXDescriptionAttribute) ?? ""
            if let u = str(el, "AXURL"), !text.isEmpty, !u.hasPrefix("javascript:") {
                add("[\(text)](\(u))")
                return // the link's children only repeat its text
            }
        case "AXImage":
            if let d = str(el, kAXDescriptionAttribute), !d.isEmpty { add("[image: \(d)]") }
        case "AXButton", "AXMenuButton", "AXPopUpButton", "AXScrollBar", "AXMenuBar":
            return // UI chrome, not content
        default:
            break
        }
        guard let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] else { return }
        for k in kids { walk(k, depth: depth + 1) }
    }
}

// MARK: - SQLite

func openDB(_ path: String) -> OpaquePointer? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
    sqlite3_busy_timeout(db, 2000)
    return db
}

func query(_ db: OpaquePointer, _ sql: String, _ binds: [Any] = []) -> [[Any?]] {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (i, b) in binds.enumerated() {
        if let n = b as? Int { sqlite3_bind_int64(stmt, Int32(i + 1), Int64(n)) }
        else if let s = b as? String { sqlite3_bind_text(stmt, Int32(i + 1), s, -1, transient) }
    }
    var rows: [[Any?]] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        rows.append((0..<sqlite3_column_count(stmt)).map { c -> Any? in
            switch sqlite3_column_type(stmt, c) {
            case SQLITE_INTEGER: return Int(sqlite3_column_int64(stmt, c))
            case SQLITE_TEXT: return String(cString: sqlite3_column_text(stmt, c))
            case SQLITE_BLOB:
                let n = Int(sqlite3_column_bytes(stmt, c))
                return n > 0 ? Data(bytes: sqlite3_column_blob(stmt, c), count: n) : nil
            default: return nil
            }
        })
    }
    return rows
}

// MARK: - Messages

let home = FileManager.default.homeDirectoryForCurrentUser.path

func contactKey(_ handle: String) -> String {
    if handle.contains("@") { return handle.lowercased() }
    return String(handle.filter(\.isNumber).suffix(10))
}

// Handle (phone/email) -> contact name, from the local AddressBook databases.
func loadContacts() -> [String: String] {
    var names: [String: String] = [:]
    let base = "\(home)/Library/Application Support/AddressBook"
    var paths = ["\(base)/AddressBook-v22.abcddb"]
    if let srcs = try? FileManager.default.contentsOfDirectory(atPath: "\(base)/Sources") {
        paths += srcs.map { "\(base)/Sources/\($0)/AddressBook-v22.abcddb" }
    }
    for p in paths where FileManager.default.fileExists(atPath: p) {
        guard let db = openDB(p) else { continue }
        defer { sqlite3_close(db) }
        let nameSQL = "TRIM(COALESCE(r.ZFIRSTNAME,'') || ' ' || COALESCE(r.ZLASTNAME,'')), r.ZORGANIZATION"
        let rows = query(db, "SELECT p.ZFULLNUMBER, \(nameSQL) FROM ZABCDPHONENUMBER p JOIN ZABCDRECORD r ON r.Z_PK = p.ZOWNER")
            + query(db, "SELECT e.ZADDRESS, \(nameSQL) FROM ZABCDEMAILADDRESS e JOIN ZABCDRECORD r ON r.Z_PK = e.ZOWNER")
        for r in rows {
            guard let h = r[0] as? String else { continue }
            let person = (r[1] as? String) ?? ""
            let name = person.isEmpty ? (r[2] as? String ?? "") : person
            let k = contactKey(h)
            if !name.isEmpty && !k.isEmpty { names[k] = name }
        }
    }
    return names
}

// Newer macOS versions store message text only in attributedBody, a typedstream-archived NSAttributedString.
// Parse the embedded NSString directly; NSUnarchiver raises uncatchable exceptions on odd blobs.
func bodyText(_ blob: Data?) -> String? {
    guard let b = blob, let r = b.range(of: Data("NSString".utf8)) else { return nil }
    var i = r.upperBound + 5
    guard i < b.count else { return nil }
    var len = Int(b[i])
    i += 1
    if len == 0x81, i + 2 <= b.count {
        len = Int(b[i]) | Int(b[i + 1]) << 8
        i += 2
    } else if len == 0x82, i + 4 <= b.count {
        len = Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
        i += 4
    }
    guard i + len <= b.count else { return nil }
    return String(data: b.subdata(in: i..<(i + len)), encoding: .utf8)
}

// Messages stores dates as nanoseconds (or, in old rows, seconds) since 2001-01-01.
func appleDate(_ v: Int) -> Date {
    Date(timeIntervalSinceReferenceDate: v > 1_000_000_000_000 ? Double(v) / 1e9 : Double(v))
}

let iso = ISO8601DateFormatter()

func openMessages() -> OpaquePointer {
    let path = "\(home)/Library/Messages/chat.db"
    guard FileManager.default.isReadableFile(atPath: path), let db = openDB(path),
          !query(db, "SELECT 1 FROM message LIMIT 1").isEmpty
    else { fail("Cannot read Messages. Turn on Agent Peek under System Settings → Privacy & Security → Full Disk Access, then retry.") }
    return db
}

func chatNames(_ db: OpaquePointer, _ contacts: [String: String]) -> [Int: String] {
    var members: [Int: [String]] = [:]
    for r in query(db, "SELECT chj.chat_id, h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id") {
        guard let c = r[0] as? Int, let h = r[1] as? String else { continue }
        members[c, default: []].append(contacts[contactKey(h)] ?? h)
    }
    var names: [Int: String] = [:]
    for r in query(db, "SELECT ROWID, display_name, chat_identifier FROM chat") {
        guard let c = r[0] as? Int else { continue }
        let display = (r[1] as? String) ?? ""
        names[c] = !display.isEmpty ? display : members[c]?.joined(separator: ", ") ?? (r[2] as? String ?? "")
    }
    return names
}

func messageJSON(_ r: [Any?], _ contacts: [String: String]) -> [String: Any]? {
    // Columns: ROWID, date, is_from_me, handle, text, attributedBody, has_attachments, chat_id
    let text = (r[4] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? bodyText(r[5] as? Data)
    let hasAttachment = (r[6] as? Int ?? 0) == 1
    guard text != nil || hasAttachment else { return nil }
    let handle = r[3] as? String ?? ""
    var m: [String: Any] = [
        "date": iso.string(from: appleDate(r[1] as? Int ?? 0)),
        "from": (r[2] as? Int) == 1 ? "me" : (contacts[contactKey(handle)] ?? handle),
        "text": (text ?? "").replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines),
    ]
    if hasAttachment { m["attachment"] = true }
    if let c = r[7] as? Int { m["chatId"] = c }
    return m
}

let messageColumns = "m.ROWID, m.date, m.is_from_me, h.id, m.text, m.attributedBody, m.cache_has_attachments, cmj.chat_id"
let messageFrom = """
    FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    LEFT JOIN handle h ON h.ROWID = m.handle_id
    WHERE m.associated_message_type = 0
    """

// MARK: - Commands

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: peek-helper list | text <windowId> [maxChars] | shot <windowId> <out.png>") }

// Full Disk Access has no query API; reading a protected file is the test.
func fullDiskAccess() -> Bool {
    (try? FileHandle(forReadingFrom: URL(fileURLWithPath: "\(home)/Library/Messages/chat.db"))) != nil
}

func permissions() -> [String: Any] {
    ["accessibility": AXIsProcessTrusted(), "screenRecording": CGPreflightScreenCaptureAccess(), "fullDiskAccess": fullDiskAccess(),
     "app": Bundle.main.bundlePath]
}

switch args[1] {
case "status":
    emit(permissions())

case "request-access":
    if !AXIsProcessTrusted() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
    emit(permissions())

case "list":
    let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
    let wins = windows()
    emit([
        "accessibilityTrusted": AXIsProcessTrusted(),
        "screenRecording": CGPreflightScreenCaptureAccess(),
        "frontmostApp": NSWorkspace.shared.frontmostApplication?.localizedName ?? "",
        "windows": wins.enumerated().map { i, w -> [String: Any] in [
            "id": w.id, "app": w.app, "title": w.title, "pid": Int(w.pid),
            "bundleId": NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier ?? "",
            "zOrder": i, "isFrontmostApp": w.pid == front, "state": state(of: w),
            "bounds": ["x": w.bounds.minX, "y": w.bounds.minY, "w": w.bounds.width, "h": w.bounds.height],
        ] },
    ])

case "text":
    guard args.count >= 3, let id = Int(args[2]) else { fail("text needs a windowId") }
    let maxChars = args.count >= 4 ? Int(args[3]) ?? 60000 : 60000
    guard let w = windows().first(where: { $0.id == id }) else { fail("window \(id) not on screen") }
    guard AXIsProcessTrusted() else { fail("Turn on Agent Peek under System Settings → Privacy & Security → Accessibility, then retry.") }
    guard let axw = axWindow(for: w) else { fail("no accessibility window for \(w.app)") }
    var c = Collector(maxChars: maxChars, deadline: Date().addingTimeInterval(6))
    c.walk(axw, depth: 0)
    // Chromium sometimes builds its tree lazily after the first request; retry once.
    if c.lines.count < 3 {
        Thread.sleep(forTimeInterval: 0.4)
        c = Collector(maxChars: maxChars, deadline: Date().addingTimeInterval(6))
        c.walk(axw, depth: 0)
    }
    var out: [String: Any] = [
        "id": w.id, "app": w.app, "title": str(axw, kAXTitleAttribute) ?? w.title,
        "text": c.lines.joined(separator: "\n"), "chars": c.chars, "nodes": c.nodes, "truncated": c.truncated,
    ]
    if let u = c.webURL { out["url"] = u }
    if let d = str(axw, kAXDocumentAttribute) { out["documentPath"] = URL(string: d)?.path ?? d }
    emit(out)

case "shot":
    guard args.count >= 4, let id = Int(args[2]) else { fail("shot needs a windowId and output path") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-o", "-l\(id)", args[3]]
    try! p.run()
    p.waitUntilExit()
    if p.terminationStatus != 0 { fail("screencapture failed for window \(id)") }
    emit(["path": args[3]])

case "ocr":
    guard args.count >= 3, let img = NSImage(contentsOfFile: args[2]),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fail("ocr needs a readable image path") }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    try? VNImageRequestHandler(cgImage: cg).perform([req])
    let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    emit(["text": lines.joined(separator: "\n"), "chars": lines.reduce(0) { $0 + $1.count + 1 }])

case "pdf":
    guard args.count >= 3, let doc = PDFDocument(url: URL(fileURLWithPath: args[2])) else { fail("cannot open PDF") }
    let maxChars = args.count >= 4 ? Int(args[3]) ?? 60000 : 60000
    var text = ""
    for i in 0..<doc.pageCount where text.count < maxChars {
        text += "--- page \(i + 1) ---\n" + (doc.page(at: i)?.string ?? "") + "\n"
    }
    emit(["pages": doc.pageCount, "text": String(text.prefix(maxChars)), "truncated": text.count > maxChars])

case "clipboard":
    let pb = NSPasteboard.general
    var out: [String: Any] = ["types": (pb.types ?? []).map(\.rawValue)]
    if let s = pb.string(forType: .string) { out["text"] = s }
    if let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !files.isEmpty {
        out["files"] = files.map(\.path)
    } else if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
        out["urls"] = urls.map(\.absoluteString)
    }
    if args.count >= 3, out["files"] == nil, let img = NSImage(pasteboard: pb),
       let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: args[2]))
        out["imagePath"] = args[2]
    }
    emit(out)

case "messages-chats":
    let limit = args.count >= 3 ? Int(args[2]) ?? 30 : 30
    let db = openMessages()
    let contacts = loadContacts()
    let names = chatNames(db, contacts)
    let rows = query(db, """
        SELECT cmj.chat_id, MAX(m.date), COUNT(*) FROM chat_message_join cmj JOIN message m ON m.ROWID = cmj.message_id
        GROUP BY cmj.chat_id ORDER BY MAX(m.date) DESC LIMIT ?
        """, [limit])
    emit(["chats": rows.map { r -> [String: Any] in [
        "chatId": r[0] as? Int ?? 0, "name": names[r[0] as? Int ?? 0] ?? "",
        "lastMessage": iso.string(from: appleDate(r[1] as? Int ?? 0)), "messageCount": r[2] as? Int ?? 0,
    ] }])

case "messages-read":
    guard args.count >= 3, let chat = Int(args[2]) else { fail("messages-read needs a chatId") }
    let limit = args.count >= 4 ? Int(args[3]) ?? 50 : 50
    let before = args.count >= 5 ? Int(args[4]) ?? 0 : 0
    let db = openMessages()
    let contacts = loadContacts()
    // Unix seconds -> Messages nanoseconds since 2001.
    let beforeApple = before > 0 ? Int((Double(before) - Date.timeIntervalBetween1970AndReferenceDate) * 1e9) : Int.max
    let rows = query(db, "SELECT \(messageColumns) \(messageFrom) AND cmj.chat_id = ? AND m.date < ? ORDER BY m.date DESC LIMIT ?", [chat, beforeApple, limit])
    emit([
        "chatId": chat, "name": chatNames(db, contacts)[chat] ?? "",
        "messages": rows.reversed().compactMap { messageJSON($0, contacts) },
    ])

case "messages-search":
    guard args.count >= 3 else { fail("messages-search needs a query") }
    let needle = args[2].lowercased()
    let limit = args.count >= 4 ? Int(args[3]) ?? 30 : 30
    let db = openMessages()
    let contacts = loadContacts()
    let names = chatNames(db, contacts)
    // The text column is often empty on recent macOS, so decode and match in Swift over the newest 50k messages.
    var hits: [[String: Any]] = []
    for r in query(db, "SELECT \(messageColumns) \(messageFrom) ORDER BY m.date DESC LIMIT 50000") {
        guard var m = messageJSON(r, contacts), (m["text"] as? String ?? "").lowercased().contains(needle) else { continue }
        m["chat"] = names[m["chatId"] as? Int ?? 0] ?? ""
        hits.append(m)
        if hits.count >= limit { break }
    }
    emit(["query": args[2], "matches": hits])

default:
    fail("unknown command \(args[1])")
}
