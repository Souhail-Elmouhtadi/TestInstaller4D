import Foundation
import PDFKit
import NaturalLanguage
import AppKit

// Automatic ReadMe analysis for the 4D release checklist.
// Usage: readme_check <ReadMe.pdf|.txt|.rtf> <version major> <tested lang EN|FR|DE|CS|JA> <plugins delivered 0|1> [words to ignore file]
// Output: one line per check, "OK|KO|INFO<TAB>message". Exit code 0.

let args = CommandLine.arguments
guard args.count >= 5 else { print("KO\tusage: readme_check file major lang plugins"); exit(0) }
let file = URL(fileURLWithPath: args[1]), major = args[2], tested = args[3].lowercased(), pluginsDelivered = args[4] == "1"

func out(_ s: String, _ m: String) { print("\(s)\t\(m.replacingOccurrences(of: "\n", with: " "))") }
// issue in one language section: fails only for the tested language, warning for the others
func issue(_ l: String, _ m: String) { out(l == tested ? "KO" : "WARN", m) }

// ---------- text extraction (one string per page) ----------
var pages: [String] = []
if file.pathExtension.lowercased() == "pdf" {
    guard let doc = PDFDocument(url: file) else { out("KO", "Cannot open PDF \(file.lastPathComponent)"); exit(0) }
    for i in 0..<doc.pageCount { pages.append(doc.page(at: i)?.string ?? "") }
} else if let a = try? NSAttributedString(url: file, options: [:], documentAttributes: nil) {
    pages = [a.string]
} else if let t = try? String(contentsOf: file, encoding: .utf8) {
    pages = [t]
}
let all = pages.joined(separator: "\n")
if all.trimmingCharacters(in: .whitespacesAndNewlines).count < 200 { out("KO", "No readable text in \(file.lastPathComponent)"); exit(0) }
out("INFO", "\(file.lastPathComponent) : \(pages.count) page(s), \(all.count) characters")

// ---------- language sections ----------
let names: [String: String] = ["en": "English", "fr": "Français", "es": "Español", "de": "Deutsch", "ja": "日本語", "pt": "Português", "cs": "Čeština"]
let expected = ["en", "fr", "es", "de", "ja", "pt", "cs"]
func lang(_ s: String) -> (String, Double) {
    let r = NLLanguageRecognizer(); r.processString(s)
    guard let l = r.dominantLanguage else { return ("?", 0) }
    return (l.rawValue, r.languageHypotheses(withMaximum: 1)[l] ?? 0)
}
var sections: [(lang: String, text: String)] = []
for p in pages where p.count > 300 {
    let (l, _) = lang(p)
    if let last = sections.last, last.lang == l { sections[sections.count - 1].text += "\n" + p } else { sections.append((l, p)) }
}
let found = sections.map { $0.lang }
let missing = expected.filter { !found.contains($0) }
if missing.isEmpty { out("OK", "Languages found : " + found.map { names[$0] ?? $0 }.joined(separator: ", ")) }
else { out("KO", "Missing language section(s) : " + missing.map { names[$0] ?? $0 }.joined(separator: ", ") + " (found : \(found.joined(separator: ",")))") }
let dup = Dictionary(grouping: found, by: { $0 }).filter { $0.value.count > 1 }.keys
if !dup.isEmpty { out("KO", "Language section split / repeated : \(dup.joined(separator: ","))") }
if !found.contains(tested) { out("KO", "No section for the tested language \(tested.uppercased())") }

// ---------- version / platform coherence ----------
let verRx = try! NSRegularExpression(pattern: "4D\\s+v?(\\d{2})(?!\\d)")
var majors: [String: Int] = [:]
for m in verRx.matches(in: all, range: NSRange(all.startIndex..., in: all)) {
    if let r = Range(m.range(at: 1), in: all) { majors[String(all[r]), default: 0] += 1 }
}
let other = majors.filter { $0.key != major }
if majors[major] == nil { out("KO", "Version 4D \(major) not mentioned") }
else if !other.isEmpty { out("KO", "Other 4D version(s) mentioned : " + other.map { "4D \($0.key) (×\($0.value))" }.joined(separator: ", ") + " – expected 4D \(major)") }
else { out("OK", "Version : only 4D \(major) mentioned (×\(majors[major]!))") }
for (l, t) in sections where !t.lowercased().contains("4d \(major)") {
    issue(l, "\(names[l] ?? l) : 4D \(major) not mentioned in this section")
}
let win = all.components(separatedBy: "Windows").count - 1
if !all.contains("macOS") { out("KO", "'macOS' not mentioned (macOS ReadMe expected)") }
else if win > 0 { out("KO", "'Windows' mentioned \(win) time(s) in the macOS ReadMe") }
else { out("OK", "Platform : macOS ReadMe") }

// ---------- coherence with the DMG content ----------
let icSections = sections.filter { $0.text.contains("Internet Commands") }.map { names[$0.lang] ?? $0.lang }
if pluginsDelivered {
    if icSections.isEmpty { out("KO", "4D Internet Commands delivered in the DMG but not mentioned in the ReadMe") }
    else { out("OK", "Plugins : 4D Internet Commands delivered and documented") }
} else if !icSections.isEmpty {
    out("KO", "ReadMe still mentions 4D Internet Commands although no plugin is delivered (\(icSections.joined(separator: ", ")))")
} else { out("OK", "Plugins : none delivered, none documented") }

// ---------- same web links in every language, one 4D e-mail per language ----------
let urlRx = try! NSRegularExpression(pattern: "https?://[A-Za-z0-9./_%#?=&~+-]+")
let mailRx = try! NSRegularExpression(pattern: "[A-Za-z0-9._%+-]+@4d\\.com")
func matches(_ rx: NSRegularExpression, _ s: String) -> [String] {
    rx.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
}
func links(_ s: String) -> Set<String> {
    Set(matches(urlRx, s).map {
        var u = $0.lowercased().replacingOccurrences(of: "://www.", with: "://")
        while let c = u.last, ".,;:/".contains(c) { u.removeLast() }
        return u
    })
}
if let en = sections.first(where: { $0.lang == "en" }) {
    let ref = links(en.text)
    var linkOK = true
    for (l, t) in sections where l != "en" {
        let s = links(t), miss = ref.subtracting(s), extra = s.subtracting(ref)
        if !miss.isEmpty || !extra.isEmpty {
            linkOK = false
            issue(l, "\(names[l] ?? l) : links differ from English" + (miss.isEmpty ? "" : " – missing \(miss.sorted().joined(separator: " "))") + (extra.isEmpty ? "" : " – extra \(extra.sorted().joined(separator: " "))"))
        }
    }
    if linkOK { out("OK", "Same \(ref.count) web links in every language") }
}
let noMail = sections.filter { matches(mailRx, $0.text).isEmpty }
if noMail.isEmpty { out("OK", "4D contact e-mail present in every language") }
for sec in noMail { issue(sec.lang, "\(names[sec.lang] ?? sec.lang) : no 4D contact e-mail") }

for u in Set(sections.flatMap { links($0.text) }).sorted() { print("URL\t\(u)") }

// ---------- English words left in translated sections (e.g. "sur le to https://") ----------
let enWords = try! NSRegularExpression(pattern: "(?<![\\p{L}'’])(the|to|and|with|your|you|for|please)(?![\\p{L}'’])")
let validHere: [String: Set<String>] = ["pt": ["for"], "cs": ["to"]] // real words in these languages
var leftovers: [String: [String]] = [:]
for (l, t) in sections where ["fr", "es", "de", "pt", "cs"].contains(l) {
    for line in t.components(separatedBy: "\n") {
        // ignore URLs and quoted UI labels such as “Click here to start a free trial”
        let ln = line.replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[“\"«][^”\"»]*([”\"»]|$)", with: "", options: .regularExpression)
        for m in enWords.matches(in: ln, range: NSRange(ln.startIndex..., in: ln)) {
            if let r = Range(m.range, in: ln), !(validHere[l]?.contains(String(ln[r])) ?? false) {
                leftovers[l, default: []].append("“…\(line.trimmingCharacters(in: .whitespaces).prefix(80))” (‘\(ln[r])’)")
            }
        }
    }
}
if leftovers.isEmpty { out("OK", "No English word left in the FR/ES/DE/PT/CS sections") }
for (l, v) in leftovers.sorted(by: { $0.key < $1.key }) { issue(l, "\(names[l] ?? l) : English word left in translation : " + v.prefix(4).joined(separator: " | ")) }

// ---------- encoding / placeholders ----------
let bad = ["\u{FFFD}", "Ã©", "Ã¨", "Ã ", "â€", "TODO", "XXX", "FIXME", "Lorem ipsum", "[[", "]]", "{{", "}}"]
let badFound = bad.filter { b in all.range(of: "(?<![\\p{L}])" + NSRegularExpression.escapedPattern(for: b) + "(?![\\p{L}])", options: .regularExpression) != nil }
if badFound.isEmpty { out("OK", "No encoding error / placeholder") } else { out("KO", "Suspicious text : \(badFound.joined(separator: " "))") }

// ---------- untranslated paragraphs ----------
var untranslated: [String] = []
for (l, t) in sections where l != "en" {
    for line in t.components(separatedBy: "\n") {
        let words = line.split(separator: " ").count
        guard words >= 8 else { continue }
        let (ll, c) = lang(line)
        if ll == "en" && c > 0.85 { untranslated.append("\(names[l] ?? l): “\(line.prefix(70))…”") }
    }
}
if untranslated.isEmpty { out("OK", "No untranslated (English) sentence in the other languages") }
for u in untranslated { issue(names.first(where: { u.hasPrefix($0.value + ":") })?.key ?? "", "Untranslated sentence : " + u) }

// ---------- spelling of the tested language ----------
let ignore: Set<String> = ["4d", "github", "rdbms", "readme", "macos", "ios", "android", "rest", "sql", "url", "pdf", "lisez-moi", "liesmich", "léame", "plug-in", "plug-ins", "plugin", "plugins", "4dbase", "rx", "lts", "hdi", "web", "wizard", "copyright", "email", "e-mail"]
if let sec = sections.first(where: { $0.lang == tested }), tested != "ja" {
    let sc = NSSpellChecker.shared
    let langCode = ["en": "en", "fr": "fr", "es": "es", "de": "de", "cs": "cs"][tested] ?? tested
    let extra = (CommandLine.arguments.count > 5 ? (try? String(contentsOfFile: CommandLine.arguments[5], encoding: .utf8)) ?? "" : "")
        .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
    let ignoreAll = ignore.union(extra)
    if sc.setLanguage(langCode) || sc.availableLanguages.contains(where: { $0.hasPrefix(langCode) }) {
        let text = sec.text.replacingOccurrences(of: "(https?://\\S+|\\S+@\\S+)", with: " ", options: .regularExpression).precomposedStringWithCanonicalMapping
        var errors: [String] = [], start = 0
        let ns = text as NSString
        while start < ns.length {
            let r = sc.checkSpelling(of: text, startingAt: start, language: langCode, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if r.location == NSNotFound || r.length == 0 { break }
            let w = ns.substring(with: r)
            let lw = w.lowercased()
            if !ignoreAll.contains(lw) && w.rangeOfCharacter(from: .decimalDigits) == nil && !(w.first?.isUppercase ?? false) && !errors.contains(w) { errors.append(w) }
            start = r.location + r.length
        }
        if errors.isEmpty { out("OK", "Spelling (\(tested.uppercased())) : no error found") }
        else { out("KO", "Spelling (\(tested.uppercased())) : \(errors.count) unknown word(s) : \(errors.prefix(15).joined(separator: ", "))") }
    } else { out("INFO", "Spelling (\(tested.uppercased())) : no macOS dictionary for this language") }
} else if tested == "ja" {
    out("INFO", "Spelling (JA) : not checked (no Japanese spell checker in macOS) – language detection only")
}
