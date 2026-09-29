import Foundation
#if canImport(Combine)
import Combine
#else
import OpenCombine
#endif

/// One DDL / schedule entry shown on the island's energy bar.
struct DeadlineItem: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var title: String
    var due: Date
    var createdAt: Date
    var isDone: Bool

    init(
        id: UUID = UUID(),
        title: String,
        due: Date,
        createdAt: Date = Date(),
        isDone: Bool = false
    ) {
        self.id = id
        self.title = title
        self.due = due
        self.createdAt = createdAt
        self.isDone = isDone
    }

    func remaining(now: Date) -> TimeInterval {
        due.timeIntervalSince(now)
    }

    /// 1 = just added, 0 = due. The drain window runs from creation to due, clamped to 1h...14d.
    func energy(now: Date) -> Double {
        let window = min(max(due.timeIntervalSince(createdAt), 3600), 14 * 86_400)
        return min(max(remaining(now: now) / window, 0), 1)
    }

    func urgency(now: Date) -> DeadlineUrgency {
        if isDone { return .done }
        let left = remaining(now: now)
        if left < 0 { return .overdue }
        if left < 86_400 { return .critical }
        if left < 3 * 86_400 { return .soon }
        return .relaxed
    }
}

/// Color band for the single energy bar, based on how many tasks it holds.
enum EnergyLoad: Equatable, Sendable {
    /// 3 cells or fewer.
    case calm
    /// 4 to 6 cells.
    case busy
    /// 7 cells or more.
    case overloaded

    static func level(for count: Int) -> EnergyLoad {
        switch count {
        case ...3: .calm
        case 4...6: .busy
        default: .overloaded
        }
    }

    var label: String {
        switch self {
        case .calm: "绿色"
        case .busy: "橙色"
        case .overloaded: "红色"
        }
    }
}

enum DeadlineUrgency: Int, Comparable, Sendable {
    case overdue
    case critical
    case soon
    case relaxed
    case done

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .overdue: "已超时"
        case .critical: "24 小时内"
        case .soon: "3 天内"
        case .relaxed: "时间充裕"
        case .done: "已完成"
        }
    }

    /// Worth showing on the collapsed peek strip.
    var isPressing: Bool { self <= .soon }
}

struct DeadlineSummary: Equatable, Sendable {
    var next: DeadlineItem?
    var overdueCount: Int
    var withinWeekCount: Int
    var pendingCount: Int
}

enum DeadlineFormat {
    static func countdown(_ interval: TimeInterval) -> String {
        let text = span(abs(interval))
        return interval < 0 ? "超时 \(text)" : "还剩 \(text)"
    }

    /// Two-to-four characters for the peek strip: `45分` / `5小时` / `2天` / `超时`.
    static func short(_ interval: TimeInterval) -> String {
        if interval < 0 { return "超时" }
        if interval < 3600 { return "\(max(1, Int(interval / 60)))分" }
        if interval < 86_400 { return "\(Int(interval / 3600))小时" }
        return "\(Int(interval / 86_400))天"
    }

    static func span(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "不到 1 分钟" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟" }
        if seconds < 86_400 {
            let hours = Int(seconds / 3600)
            let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分" : "\(hours) 小时"
        }
        let days = Int(seconds / 86_400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3600)
        return hours > 0 ? "\(days) 天 \(hours) 小时" : "\(days) 天"
    }

    /// `今天 18:00` / `明天 09:30` / `周五 23:59` / `10月3日 18:00`.
    static func dueLabel(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        let day: String
        switch days {
        case -1: day = "昨天"
        case 0: day = "今天"
        case 1: day = "明天"
        case 2: day = "后天"
        case 3..<7:
            let names = ["日", "一", "二", "三", "四", "五", "六"]
            day = "周" + names[((parts.weekday ?? 1) - 1 + 7) % 7]
        default:
            let sameYear = calendar.component(.year, from: now) == parts.year
            day = sameYear
                ? "\(parts.month ?? 1)月\(parts.day ?? 1)日"
                : "\(parts.year ?? 0)年\(parts.month ?? 1)月\(parts.day ?? 1)日"
        }
        return "\(day) \(time)"
    }
}

/// What the parser found in a line like `周五 18:00 交实验报告`.
struct ParsedDeadline: Equatable, Sendable {
    var title: String
    var due: Date?
    /// Date / time words that were recognised, for the “识别为” hint.
    var matched: [String]
}

/// Pulls a due date out of free Chinese text: 今天 / 明天 / 后天 / 大后天, 周X / 下周X,
/// M月D日 / M/D, N天后 / N小时后 / N分钟后, HH:mm / 下午3点半. Date only → 23:59.
/// Time only → today, or tomorrow once that time has passed.
enum DeadlineParser {
    private static let meridiem = "(上午|早上|中午|下午|傍晚|晚上|凌晨)?"
    private static let cnDigits = "零一二两三四五六七八九十"

    static func parse(_ input: String, now: Date = Date(), calendar: Calendar = .current) -> ParsedDeadline {
        var text = input
        var matched: [String] = []
        var exactInterval: TimeInterval?
        var dayDate: Date?
        var hour: Int?
        var minute = 0
        var evening = false
        let today = calendar.startOfDay(for: now)

        if let hit = take(#"(\d+|[\#(cnDigits)]+)\s*个?\s*(天|周|星期|小时|钟头|分钟)[之以]?后"#, from: &text, matched: &matched) {
            if let count = number(hit[0]) {
                switch hit[1] ?? "" {
                case "天": dayDate = calendar.date(byAdding: .day, value: count, to: today)
                case "周", "星期": dayDate = calendar.date(byAdding: .day, value: 7 * count, to: today)
                case "小时", "钟头": exactInterval = TimeInterval(count) * 3600
                default: exactInterval = TimeInterval(count) * 60
                }
            }
        }

        if dayDate == nil, exactInterval == nil,
           let hit = take(#"(?:(\d{4})[年/\-.])?(\d{1,2})[月/\-.](\d{1,2})[日号]?"#, from: &text, matched: &matched) {
            let month = number(hit[1]) ?? 0
            let day = number(hit[2]) ?? 0
            let explicitYear = number(hit[0])
            var parts = DateComponents()
            parts.year = explicitYear ?? calendar.component(.year, from: now)
            parts.month = month
            parts.day = day
            if (1...12).contains(month), (1...31).contains(day), var date = calendar.date(from: parts) {
                if explicitYear == nil, date < today,
                   let nextYear = calendar.date(byAdding: .year, value: 1, to: date) {
                    date = nextYear
                }
                dayDate = date
            }
        }

        if dayDate == nil, exactInterval == nil,
           let hit = take(#"(下下|下|这|本)?(?:周|星期|礼拜)([一二三四五六日天1-7])"#, from: &text, matched: &matched),
           let target = weekdayIndex(hit[1]) {
            let current = (calendar.component(.weekday, from: now) + 5) % 7
            let offset: Int
            switch hit[0] ?? "" {
            case "下": offset = 7 - current + target
            case "下下": offset = 14 - current + target
            default: offset = (target - current + 7) % 7
            }
            dayDate = calendar.date(byAdding: .day, value: offset, to: today)
        }

        if let hit = take("(大后天|后天|明天|明早|明晚|今天|今早|今晚)", from: &text, matched: &matched) {
            let word = hit[0] ?? ""
            evening = word.hasSuffix("晚")
            if dayDate == nil, exactInterval == nil {
                let offset: Int
                switch word {
                case "大后天": offset = 3
                case "后天": offset = 2
                case "明天", "明早", "明晚": offset = 1
                default: offset = 0
                }
                dayDate = calendar.date(byAdding: .day, value: offset, to: today)
            }
        }

        if exactInterval == nil {
            if let hit = take(meridiem + #"\s*(\d{1,2})[:：](\d{2})"#, from: &text, matched: &matched) {
                hour = adjust(hour: number(hit[1]), meridiem: hit[0], evening: evening)
                minute = number(hit[2]) ?? 0
            } else if let hit = take(
                meridiem + #"\s*(\d{1,2}|[\#(cnDigits)]{1,3})[点时](半|(\d{1,2})分?)?"#,
                from: &text,
                matched: &matched
            ) {
                hour = adjust(hour: number(hit[1]), meridiem: hit[0], evening: evening)
                minute = hit[2] == "半" ? 30 : (number(hit[3]) ?? 0)
            }
        }
        if let value = hour, !(0...23).contains(value) { hour = nil }
        if !(0...59).contains(minute) { minute = 0 }

        let due: Date?
        if let exactInterval {
            due = now.addingTimeInterval(exactInterval)
        } else if let dayDate {
            due = calendar.date(bySettingHour: hour ?? 23, minute: hour == nil ? 59 : minute, second: 0, of: dayDate)
        } else if let hour, let todayAt = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today) {
            if todayAt > now {
                due = todayAt
            } else {
                due = calendar.date(byAdding: .day, value: 1, to: todayAt)
            }
        } else {
            due = nil
        }

        return ParsedDeadline(title: cleanTitle(text), due: due, matched: matched)
    }

    // MARK: - Helpers

    /// First match of `pattern`; removes it from `text` and returns its capture groups.
    private static func take(_ pattern: String, from text: inout String, matched: inout [String]) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        var groups: [String?] = []
        if match.numberOfRanges > 1 {
            for index in 1..<match.numberOfRanges {
                let range = match.range(at: index)
                groups.append(range.location == NSNotFound ? nil : ns.substring(with: range))
            }
        }
        matched.append(ns.substring(with: match.range).trimmingCharacters(in: .whitespaces))
        text = ns.replacingCharacters(in: match.range, with: " ")
        return groups
    }

    private static func adjust(hour: Int?, meridiem: String?, evening: Bool) -> Int? {
        guard let hour else { return nil }
        switch meridiem ?? "" {
        case "下午", "傍晚", "晚上":
            return hour < 12 ? hour + 12 : hour
        case "中午":
            return hour < 11 ? hour + 12 : hour
        case "":
            return evening && hour < 12 ? hour + 12 : hour
        default:
            return hour
        }
    }

    private static func weekdayIndex(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let names = ["一", "二", "三", "四", "五", "六", "日"]
        if let index = names.firstIndex(of: raw) { return index }
        if raw == "天" { return 6 }
        if let digit = Int(raw), (1...7).contains(digit) { return digit - 1 }
        return nil
    }

    /// Arabic digits, or Chinese numerals up to 九十九 (十二, 两, 二十三…).
    static func number(_ raw: String?) -> Int? {
        guard let raw, !raw.isEmpty else { return nil }
        if let value = Int(raw) { return value }
        let digits: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
            "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
        ]
        let chars = Array(raw)
        if let tenIndex = chars.firstIndex(of: "十") {
            let tensPart = chars[..<tenIndex]
            let onesPart = chars[(tenIndex + 1)...]
            guard tensPart.count <= 1, onesPart.count <= 1 else { return nil }
            var tens = 1
            var ones = 0
            if let char = tensPart.first {
                guard let value = digits[char] else { return nil }
                tens = value
            }
            if let char = onesPart.first {
                guard let value = digits[char] else { return nil }
                ones = value
            }
            return tens * 10 + ones
        }
        guard chars.count == 1 else { return nil }
        return digits[chars[0]]
    }

    private static func cleanTitle(_ raw: String) -> String {
        var title = raw.replacingOccurrences(
            of: "(?i)ddl|截止(到|于)?",
            with: " ",
            options: .regularExpression
        )
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let edge = CharacterSet(charactersIn: " ，,。.、:：;；-—~～")
        var previous = ""
        while previous != title {
            previous = title
            title = title.trimmingCharacters(in: edge)
            for word in ["之前", "以前", "前"] {
                if title.hasPrefix(word) { title.removeFirst(word.count) }
                if title.hasSuffix(word) { title.removeLast(word.count) }
            }
        }
        return title
    }
}

/// JSON-persisted DDL list, sorted by due date.
@MainActor
final class DeadlineStore: ObservableObject {
    @Published private(set) var items: [DeadlineItem] = []

    private let fileURL: URL?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// `nil` keeps the list in memory only.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = Self.sorted(loadFromDisk())
    }

    nonisolated static var defaultFileURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root
            .appendingPathComponent("GrokIsland", isDirectory: true)
            .appendingPathComponent("deadlines.json")
    }

    /// Not-done entries, soonest (including overdue) first.
    var pending: [DeadlineItem] {
        items.filter { !$0.isDone }
    }

    func summary(now: Date = Date()) -> DeadlineSummary {
        let pending = self.pending
        return DeadlineSummary(
            next: pending.first,
            overdueCount: pending.filter { $0.remaining(now: now) < 0 }.count,
            withinWeekCount: pending.filter { (0..<(7 * 86_400)).contains($0.remaining(now: now)) }.count,
            pendingCount: pending.count
        )
    }

    @discardableResult
    func add(title: String, due: Date, now: Date = Date()) throws -> DeadlineItem {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IslandError.deadlineTitleEmpty }
        let item = DeadlineItem(title: trimmed, due: due, createdAt: min(now, due))
        items = Self.sorted(items + [item])
        persist()
        return item
    }

    @discardableResult
    func update(id: UUID, title: String, due: Date) throws -> DeadlineItem {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IslandError.deadlineTitleEmpty }
        guard let index = items.firstIndex(where: { $0.id == id }) else { throw IslandError.deadlineNotFound }
        var item = items[index]
        item.title = trimmed
        if item.due != due {
            item.due = due
            item.createdAt = min(Date(), due)
        }
        items[index] = item
        items = Self.sorted(items)
        persist()
        return item
    }

    func toggleDone(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isDone.toggle()
        persist()
    }

    func delete(id: UUID) {
        let before = items.count
        items.removeAll { $0.id == id }
        if items.count != before { persist() }
    }

    @discardableResult
    func clearDone() -> Int {
        let before = items.count
        items.removeAll(where: \.isDone)
        let removed = before - items.count
        if removed > 0 { persist() }
        return removed
    }

    private static func sorted(_ items: [DeadlineItem]) -> [DeadlineItem] {
        items.sorted { lhs, rhs in
            lhs.due == rhs.due ? lhs.createdAt < rhs.createdAt : lhs.due < rhs.due
        }
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(items).write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("GrokIsland DeadlineStore: save failed: \(error.localizedDescription)")
        }
    }

    private func loadFromDisk() -> [DeadlineItem] {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            return try decoder.decode([DeadlineItem].self, from: Data(contentsOf: fileURL))
        } catch {
            NSLog("GrokIsland DeadlineStore: load failed: \(error.localizedDescription)")
            return []
        }
    }
}
