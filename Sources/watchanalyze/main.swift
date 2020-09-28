import Foundation
import NIO
import MySQLNIO
import SE0282_Experimental

struct Watch {
    let lineNumber: Int
    
    let timestamp: Date
    let creator: String
    let patternText: String
    let patternRegex: NSRegularExpression
    
    var _hitsTotal = UnsafeAtomic<Int>.create(0)
    var _hitsTP = UnsafeAtomic<Int>.create(0)
    var _hitsFP = UnsafeAtomic<Int>.create(0)
    
    var hitsTotal: Int { _hitsTotal.load(ordering: .relaxed) }
    var hitsTP: Int { _hitsTP.load(ordering: .relaxed) }
    var hitsFP: Int { _hitsFP.load(ordering: .relaxed) }
    
    func destroy() {
        _hitsTotal.destroy()
        _hitsTP.destroy()
        _hitsFP.destroy()
    }
    
    init?(_ line: String, lineNumber: Int) throws {
        self.lineNumber = lineNumber
        let components = line.components(separatedBy: "\t")
        guard components.count == 3,
              let timestamp = Int(components[0])
        else { return nil }
        
        self.timestamp = Date(timeIntervalSince1970: TimeInterval(timestamp))
        creator = components[1]
        patternText = components[2]
        
        // Clean up regex patterns to be compatible with ICU regex. In particular,
        // replace all unbounded * and + quantifiers with very long bounded
        // quantifiers (since ICU does not allow unbounded quantifiers in lookbehinds).
        // https://xkcd.com/1313/
        
        // (?<!\\)(\\\\){0,10}\\ matches an escape sequence, so
        // (?<!(?<!\\)(\\\\){0,10}\\)x matches an UNESCAPED 'x'
        let escapeSequence = "(?<!\\\\)(\\\\\\\\){0,10}\\\\"
        let unescaped = "(?<!\(escapeSequence))"
        let cleanedPattern = patternText
            
            // Get rid of +, but not \+ or *+.
            // i.e. +, but not (escapeSequence)+ or (unescaped)[*+?}]+
            .replacingOccurrences(of: "(?<!\(escapeSequence)|\(unescaped)[*+?}])\\+", with: "{1,100}", options: .regularExpression)
            
            // Get rid of *, but not \*.
            .replacingOccurrences(of: "\(unescaped)\\*", with: "{0,100}", options: .regularExpression)
        
            // Replace unbounded quantifiers {n,} with bounded ones {n,1000}.
            .replacingOccurrences(of: ",}", with: ",100}")
        
        self.patternRegex = try NSRegularExpression(
                pattern: cleanedPattern,
                options: [.caseInsensitive, .useUnicodeWordBoundaries]
        )
    }
    
    func matches(_ post: String) -> Bool {
        patternRegex.firstMatch(
            in: post,
            range: NSRange(location: 0, length: (post as NSString).length)
        ) != nil
    }
}

let eventLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
let database = try MySQLConnection.connect(
    to: .makeAddressResolvingHost("127.0.0.1", port: 3306),
    username: "metasmoke",
    database: "dump_metasmoke",
    tlsConfiguration: TLSConfiguration.forClient(certificateVerification: .none),
    on: eventLoop
).wait()

print("Loading watchlist...")
var watches = try Array(
    String(contentsOf: URL(fileURLWithPath: "watched_keywords.txt"))
        .components(separatedBy: .newlines).lazy
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        .enumerated()
        .compactMap { (lineNumber: Int, line: String) -> Watch? in
            switch Result(catching: { try Watch(line, lineNumber: lineNumber) }) {
            case .success(.some(let watch)):
                return watch
            case .success(nil):
                print("warning: could not parse regex \(line)")
                return nil
            case .failure(let error):
                print("warning: could not parse regex \(line): \(error)")
                return nil
            }
        }
)

let mysqlDateFormatter = DateFormatter()
mysqlDateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
mysqlDateFormatter.timeZone = TimeZone(abbreviation: "UTC")!

// Pull posts from the database and dispatch them onto worker threads.
let queue = DispatchQueue(label: "com.nobodynada.watchanalyze.regex", attributes: .concurrent, autoreleaseFrequency: .workItem)

// To keep memory usage down, don't pull posts faster than we can process them.
let maxInFlightPosts = 256
let sema = DispatchSemaphore(value: maxInFlightPosts)

print("Scanning posts...")
var postsScanned = 0
let query = """
SELECT p_posts.id, p_posts.body, p_posts.created_at, p_posts.is_tp, p_posts.is_naa, p_posts.is_fp
    FROM p_posts
        JOIN p_posts_reasons ON p_posts.id = p_posts_reasons.post_id
    WHERE  p_posts_reasons.reason_id = 127
        OR p_posts_reasons.reason_id = 129
    GROUP BY p_posts.id;
"""

try database.simpleQuery(query) { post in
    print("Scanned \(postsScanned) posts.")
    postsScanned += 1
    
    sema.wait()
    queue.async {
        defer { sema.signal() }
        
        guard let id = post.column("id")?.int else {
            print("warning: post has no ID")
            return
        }
        
        guard let body = post.column("body")?.string else {
            print("warning: post \(id) has no body")
            return
        }
        
        guard let creationString = post.column("created_at")?.string,
              let creation = mysqlDateFormatter.date(from: creationString) else {
            print("warning: post \(id) has no date")
            return
        }
        
        guard let isTP = post.column("is_tp")?.int.map({ $0 != 0 }),
              let isNAA = post.column("is_naa")?.int.map({ $0 != 0 }),
              let isFP = post.column("is_fp")?.int.map({ $0 != 0 })
                .map({ $0 || isNAA })   // Count NAAs as FPs
        else {
            print("warning: post \(id) is has invalid feedback")
            return
        }
        
        for watch in watches where watch.timestamp < creation && watch.matches(body) {
            watch._hitsTotal.wrappingIncrement(ordering: .relaxed)
            if isTP { watch._hitsTP.wrappingIncrement(ordering: .relaxed) }
            if isFP { watch._hitsFP.wrappingIncrement(ordering: .relaxed) }
        }
    }
}.wait()

// Wait for all inflight requests to complete.
for _ in 0..<maxInFlightPosts { sema.wait() }
atomicMemoryFence(ordering: .acquiring)
print("Scanned \(postsScanned) posts. Saving...")

// write to CSV

let csvDateFormatter = ISO8601DateFormatter()
let csv = watches.map {
    [
        String($0.lineNumber),
        csvDateFormatter.string(from: $0.timestamp),
        $0.creator, $0.patternText,
        String($0.hitsTotal), String($0.hitsTP), String($0.hitsFP)
    ].map { column -> String in
        let escaped = column
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }.joined(separator: ",")
}
let header = "line_number,timestamp,creator,pattern,total,tp,fp"
try ([header] + csv).joined(separator: "\n").write(to: URL(fileURLWithPath: "watchanalyze.csv"), atomically: true, encoding: .utf8)
