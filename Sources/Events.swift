import Cocoa
import SwiftUI

let eventsPath = ProcessInfo.processInfo.environment["VIBECAT_EVENTS"] ?? NSHomeDirectory() + "/.vibecat/events.jsonl"  // override for testing
let usagePath = (eventsPath as NSString).deletingLastPathComponent + "/usage.json"  // next to the events, so a test instance stays isolated
let defaults = UserDefaults.standard

// MARK: - Turning hook events into words

struct Bubble: Equatable {
    var icon: String, title: String, detail = "", code = "", project = ""
    var session = ""  // set when the bubble is a session waiting on you: click jumps to its terminal, close acknowledges it
}

func str(_ v: Any?) -> String { (v as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
func firstLine(_ v: Any?) -> String { str(v).components(separatedBy: .newlines)[0] }
func fileName(_ v: Any?) -> String { (str(v) as NSString).lastPathComponent }
/// Enough markdown stripping for a two-line bubble: headings, bullets, numbering, bold, backticks, newlines.
func plain(_ md: String) -> String {
    md.replacingOccurrences(of: #"(?m)^\s*(#{1,6}\s*|[-*•]\s+|\d+\.\s+)|\*\*|`+"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
}

func describe(tool: String, _ i: [String: Any]) -> Bubble {
    switch tool {
    case "Read": return Bubble(icon: "doc.text", title: "Reading", detail: fileName(i["file_path"]))
    case "Write": return Bubble(icon: "doc.badge.plus", title: "Writing", detail: fileName(i["file_path"]))
    case "Edit", "MultiEdit": return Bubble(icon: "pencil", title: "Editing", detail: fileName(i["file_path"]))
    case "NotebookEdit": return Bubble(icon: "pencil", title: "Editing", detail: fileName(i["notebook_path"]))
    case "Bash": return Bubble(icon: "terminal", title: "Running", detail: str(i["description"]), code: firstLine(i["command"]))
    case "Grep": return Bubble(icon: "magnifyingglass", title: "Searching", detail: fileName(i["path"]), code: str(i["pattern"]))
    case "Glob": return Bubble(icon: "folder", title: "Looking for files", code: str(i["pattern"]))
    case "WebFetch": return Bubble(icon: "globe", title: "Reading the web", detail: URL(string: str(i["url"]))?.host ?? str(i["url"]))
    case "WebSearch": return Bubble(icon: "globe", title: "Searching the web", detail: str(i["query"]))
    case "Task", "Agent": return Bubble(icon: "person.2", title: "Sending a helper", detail: str(i["description"]))
    case "AskUserQuestion":  // the PermissionRequest + permission_prompt that follow turn this into "Needs you · Question"
        let qs = i["questions"] as? [[String: Any]] ?? []
        return Bubble(icon: "questionmark.bubble.fill", title: qs.count > 1 ? "\(qs.count) questions" : "Question", detail: str(qs.first?["question"]))
    case "ExitPlanMode": return Bubble(icon: "list.bullet.clipboard", title: "Plan ready", detail: plain(str(i["plan"])))
    case "TodoWrite":
        let todos = i["todos"] as? [[String: Any]] ?? []
        let doing = todos.first { $0["status"] as? String == "in_progress" }
        let done = todos.filter { $0["status"] as? String == "completed" }.count
        return Bubble(icon: "checklist", title: "Plan \(done)/\(todos.count)", detail: str(doing?["activeForm"] ?? doing?["content"]))
    default:
        let parts = tool.components(separatedBy: "__")  // mcp__<server>__<tool>
        if parts.count == 3, parts[0] == "mcp" {
            let server = parts[1].replacingOccurrences(of: "claude_ai_", with: "").replacingOccurrences(of: "_", with: " ")
            return Bubble(icon: "puzzlepiece.extension", title: "Using \(server)", detail: parts[2])
        }
        return Bubble(icon: "wrench.and.screwdriver", title: "Using \(tool)")
    }
}

/// Which face a tool gets: reading is curious, editing is focused, everything else is busy.
func moodFor(tool: String) -> Mood {
    switch tool {
    case "Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch": .read
    case "Edit", "MultiEdit", "Write", "NotebookEdit": .edit
    default: .work
    }
}

let durations: DateComponentsFormatter = {
    let f = DateComponentsFormatter()
    f.allowedUnits = [.day, .hour, .minute, .second]  // days only ever show for the weekly limit
    f.unitsStyle = .abbreviated
    f.maximumUnitCount = 2
    return f
}()
