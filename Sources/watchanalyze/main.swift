import Foundation
import NIO
import MySQLNIO
import PythonKit
let regex = Python.import("regex")

let None = Python.None

// from city_list in findspam.py
let cities = [
    "Agra", "Ahmedabad", "Ajanta", "Almora", "Alwar", "Amritsar", "Andheri",
    "Bangalore", "Banswarabhiwadi", "Bhilwara", "Bhimtal", "Bhiwandi", "Bhopal",
    "Calcutta", "Calicut", "Chandigarh",
    "Chennai", "Chittorgarh", "Coimbatore", "Colaba",
    "Darjeeling", "Dehradun", "Dehrdun", "Delhi", "Dharamshala", "Dharamsala", "Durgapur",
    "Ernakulam", "Faridabad",
    "Ghatkopar", "Ghaziabad", "Gurgaon", "Gurugram",
    "Haldwani", "Haridwar", "Hyderabad",
    "Jaipur", "Jalandhar", "Jim Corbett",
    "Kandivali", "Kangra", "Kanhangad", "Kanhanjad", "Karnal", "Kerala",
    "Kochi", "Kolkata", "Kota",
    "Lokhandwala", "Lonavala", "Ludhiana",
    "Marine Lines", "Mumbai", "Madurai", "Malad", "Mangalore", "Mangaluru", "Mulund",
    "Nagpur", "Nainital", "Nashik", "Neemrana", "Noida",
    "Patna", "Pune",
    "Raipur", "Rajkot", "Ramnagar", "Rishikesh", "Rohini",
    "Sonipat", "Surat",
    "Telangana", "Tiruchi", "Tiruchirappalli", "Thane",
    "Trichinopoly", "Trichy", "Trivandrum", "Thiruvananthapuram",
    "Udaipur", "Uttarakhand",
    "Visakhapatnam", "Worli",
    // not in India
    "Dubai", "Lahore", "Lusail", "Portland",
    // yes, these aren't cities but...
    "Abu Dhabi", "Abudhabi", "India", "Malaysia", "Pakistan", "Qatar",
    // buyabans.com spammer uses creative variations
    "Sri Lanka", "Srilanka", "Srilankan",
]

struct Watch {
    let timestamp: Date
    let creator: String
    let patternText: String
    let patternRegex: PythonObject
    
    var hitsTotal = 0
    var hitsTP = 0
    var hitsFP = 0
    
    init?(line: String) {
        let components = line.components(separatedBy: "\t")
        guard components.count == 3,
              let timestamp = Int(components[0])
        else { return nil }
        
        self.timestamp = Date(timeIntervalSince1970: TimeInterval(timestamp))
        creator = components[1]
        patternText = components[2]
        
        patternRegex = regex.compile(patternText, regex.UNICODE, city: cities, ignore_unused: true)
    }
    
    func matches(_ post: String) -> Bool { patternRegex.search(post) != None }
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
        .map { (line: String) -> Watch in
            guard let watch = Watch(line: line) else {
                fatalError("watchlist entry \(line) is invalid")
            }
            return watch
        }
)

print("Scanning posts...")
var postsScanned = 0
try database.simpleQuery("SELECT * FROM p_posts") { post in
    if postsScanned % 100 == 0 {
        print("Scanned \(postsScanned) posts.")
    }
    postsScanned += 1
    
    guard let id = post.column("id")?.int else {
        print("warning: post has no ID")
        return
    }
    
    guard let body = post.column("body")?.string else {
        print("warning: post \(id) has no body")
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
    
    for i in watches.indices where watches[i].matches(body) {
        watches[i].hitsTotal += 1
        if isTP { watches[i].hitsTP += 1 }
        if isFP { watches[i].hitsFP += 1 }
    }
}.wait()

print("Scanned \(postsScanned) posts.")
