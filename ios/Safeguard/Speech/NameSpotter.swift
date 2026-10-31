import Foundation

public enum NameSpotter {
    private struct Rule {
        let regex: NSRegularExpression
        let strong: Bool
        let strongIfCapitalised: Bool
    }

    private static let word = #"([\p{L}][\p{L}\p{M}'’\-]{1,14})"#
    private static let pair = word + #"(?:\s+([\p{L}][\p{L}\p{M}'’\-]{1,14}))?"#

    private static let rules: [Rule] = {
        func make(_ pattern: String, strong: Bool = false, capitalised: Bool = false) -> Rule {
            Rule(
                regex: try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                strong: strong, strongIfCapitalised: capitalised
            )
        }
        return [
            make(#"\b(?:my\s+name\s+is|my\s+name['’]s|name\s+is|call\s+me|they\s+call\s+me)\s+"# + pair, strong: true),
            make(#"\b(?:mera|meri|mere)\s+(?:naam|name|nam)\s+(?:hai\s+)?"# + pair, strong: true),
            make(#"\bnaam\s+hai\s+"# + pair, strong: true),
            make(#"(?:मेरा|मेरी)\s+नाम\s+(?:है\s+)?"# + pair, strong: true),
            make(#"\bmain\s+"# + word + #"\s+(?:hoon|hun|hu|hoo)\b"#, capitalised: true),
            make(#"मैं\s+"# + word + #"\s+(?:हूँ|हूं|हु)"#, strong: true),
            make(#"\b(?:i\s+am|i['’]m|this\s+is|it['’]s)\s+"# + word, capitalised: true),
            make(#"\b(?:hey|hi|hello|hii|oye|arre|are|oi|listen|excuse\s+me|thanks|thank\s+you|bye|sorry|please|okay|ok)\s*,?\s+"# + word),
            make(#"\b(?:are\s+you|you\s+are|tum|aap|tu)\s+"# + word + #"(?:\s+(?:ho|hai|hain)\b|\?)"#),
        ]
    }()

    private static let stop: Set<String> = Set("""
    a about above after again all also am an and any are as at be because been before being below between both but by can \
    come could day did do does doing done down during each else even every fine first for from get give go going gone good \
    got had has have he hello her here hers hi him his how i if in into is it its just know last let like little look made \
    make many may me more most much must my near never new next no not now of off oh ok okay on once one only or other our \
    out over own please really right said same say see she should so some something sorry still such sure take tell than that \
    the their them then there these they thing think this those through to today tomorrow too under until up us very want was \
    we well were what when where which while who why will with would yes yet you your yours thanks thank bye hey listen \
    maam ma'am mam sister uncle aunty bro boss beta excuse coming looking trying waiting talking calling standing walking driving feeling ready late early back home outside \
    inside alone safe scared worried angry happy sad tired hungry busy free sorry fine okay alright
    kya hai hain hoon hun hu ho tha thi the hum tum aap tu main mai mujhe mujhko tumhe tumhara aapka mera meri mere hamara \
    nahi nahin haan ha ji bhai bhaiya didi madam sir sirji yaar dost bhaiyya arre are oye oi abhi bas bahut thoda kuch kuchh \
    kaise kaisa kaisi kahan kab kyun kyon kaun koi sab sabhi theek thik accha acha chalo chal ruko ruk aao aa jao ja \
    ghar kaam paas door yahan wahan idhar udhar upar neeche ab phir fir toh to bhi hi se ko ka ki ke mein me par pe \
    है हैं हूँ हूं हो था थी हम तुम आप तू मैं मुझे मेरा मेरी मेरे नहीं हाँ हां जी भाई दीदी मैडम सर यार क्या कहाँ कब कौन कोई सब ठीक अच्छा घर काम
    """.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\\" }).map { String($0) })

    public static func names(in text: String) -> [SpokenName] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var found: [String: SpokenName] = [:]
        for rule in rules {
            for match in rule.regex.matches(in: text, options: [], range: full) {
                var parts: [String] = []
                var firstRaw = ""
                for group in 1..<match.numberOfRanges {
                    let range = match.range(at: group)
                    guard range.location != NSNotFound else { break }
                    let raw = ns.substring(with: range)
                    guard let name = clean(raw) else { break }
                    if parts.isEmpty { firstRaw = raw }
                    parts.append(name)
                }
                guard !parts.isEmpty else { continue }
                let name = parts.joined(separator: " ")
                let capitalised = firstRaw.first?.isUppercase == true
                let strong = rule.strong || (rule.strongIfCapitalised && capitalised)
                let key = name.lowercased()
                if let old = found[key], old.rating == "strongly possible" { continue }
                found[key] = SpokenName(name: name, rating: strong ? "strongly possible" : "possible")
            }
        }
        return Array(found.values).sorted { $0.name < $1.name }
    }

    private static func clean(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "'’-"))
        guard trimmed.count >= 2, !stop.contains(trimmed.lowercased()) else { return nil }
        let isLatin = trimmed.unicodeScalars.allSatisfy { $0.isASCII }
        guard trimmed.count >= 3 || !isLatin else { return nil }
        guard !isLatin else { return trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased() }
        return trimmed
    }
}
