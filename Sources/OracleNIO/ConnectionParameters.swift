import Foundation

/// A dictionary of alternative parameter names that are used in connect descriptors, the key is the parameter name used
/// in connect descriptors and the value is the key used in argument dictionaries (and stored in the parameter objects).
let alternativeParameterNames = [
    "pool_connection_class": "cclass",
    "pool_purity": "purity",
    "server": "server_type",
    "transport_connect_timeout": "tcp_connect_timeout",
    "my_wallet_directory": "wallet_location"
]

/// A set of parameter names in connect descriptors that are treated as containers (values are always lists).
let containerParameterNames: Set<String> = ["address_list", "description", "address"]

/// Regular expression used for determining if a connect string refers to an Easy Connect string or not.
let easyConnectPattern = try! Regex("((?P<protocol>\\w+)://)?(?P<host>[^:/]+)(:(?P<port>\\d+)?)?/(?P<service_name>[^:?]*)(:(?P<server_type>\\w+))?")

/// Dictionary of tnsnames.ora files, indexed by the directory in which the file is found;
/// the results are cached in order to avoid parsing a file multiple times;
/// the modification time of the file is checked each time, though, to
/// ensure that no changes were made since the last time that the file was read and parsed.
var tnsNamesFiles: [String: TNSNamesFile] = [:]

// Internal default values
let DEFAULT_PROTOCOL = "tcp"
let DEFAULT_PORT: UInt32 = 1521
let DEFAULT_TCP_CONNECT_TIMEOUT: Double = 60

/// Adds a container to the arguments.
func addContainer(args: inout [String: Any], name: String, value: inout Any) throws {
    // TODO: autogenerated (needs a closer look down the road)
    // Any is either a dictionary, array or string, might be nested multiple levels
    var name = name
    if name == "address" && args.keys.contains("address_list") {
        value = ["address": [value]]
        name = "address_list"
    } else if name == "address_list", let addressArguments = args["address"] as? Dictionary<String, Any> {
        var newList = [Dictionary<String, Any>]()
        for v in addressArguments {
            newList.append(["address": [v]])
        }
        args[name] = newList
        args.removeValue(forKey: "address")
    }
    if args[name] == nil {
        args[name] = [value]
    } else if var nameArgs = args[name] as? Array<Any> {
        nameArgs.append(value)
        args[name] = nameArgs
    }
}

/// Internal method which parses a connect descriptor containing name-value pairs in the form (KEY = VALUE),
/// where the value can itself be another set of nested name-value pairs. A dictionary is returned containing these key value pairs.
func parseConnectDescriptor(data: String, args: inout [String: Any]) throws {
    // TODO: autogenerated (needs a closer look down the road)
    // Any is either a dictionary, array or string, might be nested multiple levels
    if data.first != "(" || data.last != ")" {
        throw OracleError.ErrorType.invalidConnectDescriptor
    }
    var data = String(data.dropFirst().dropLast())
    if let pos = data.firstIndex(of: "=") {
        var name = data[..<pos].trimmingCharacters(in: .whitespaces).lowercased()
        data = data[data.index(after: pos)...].trimmingCharacters(in: .whitespaces)
        if data.isEmpty || !data.starts(with: "(") {
            var value: Any = data
            if !(value as! String).isEmpty && (value as! String).first == "\"" && (value as! String).last == "\"" {
                value = String((value as! String).dropFirst().dropLast())
            }
            name = alternativeParameterNames[name] ?? name
            if containerParameterNames.contains(name) {
                try addContainer(args: &args, name: name, value: &value)
            } else {
                args[name] = value
            }
        } else {
            var value: [String: Any] = [:]
            while !data.isEmpty {
                var searchPos = data.index(after: data.startIndex)
                var numOpeningParens = 1
                var numClosingParens = 0
                while numClosingParens < numOpeningParens {
                    guard let endPos = data[searchPos...].firstIndex(of: ")") else {
                        throw OracleError.ErrorType.invalidConnectDescriptor
                    }
                    numClosingParens += 1
                    numOpeningParens += data[searchPos...endPos].filter { $0 == "(" }.count
                    searchPos = data.index(after: endPos)
                }
                let range = data.startIndex...searchPos
                try parseConnectDescriptor(data: String(data[range]), args: &value)
                data = String(data[searchPos...].trimmingCharacters(in: .whitespaces))
            }
            name = alternativeParameterNames[name] ?? name
            if containerParameterNames.contains(name) {
                var anyValue: Any = value
                try addContainer(args: &args, name: name, value: &anyValue)
                value = anyValue as! Dictionary<String, Any>
            } else {
                args[name] = value
            }
        }
    } else {
        throw OracleError.ErrorType.invalidConnectDescriptor
    }
}

struct Defaults {
    static let arraySize = 100
    static let statementCacheSize = 20
    static let configDirectory = ProcessInfo.processInfo.environment["TNS_ADMIN"]
    static let fetchLobs = true
    static let fetchDecimals = false
    static let prefetchRows = 2
}

struct ConnectParameters {
    let statementCacheSize = Defaults.statementCacheSize
    let configDirectory = Defaults.configDirectory
    let defaultDescription: Description
    let defaultAddress: Address
    let descriptionList: DescriptionList
    private(set) var password: [UInt8]? = nil
    private(set) var passwordObfuscator: [UInt8]? = nil
    private(set) var newPassword: [UInt8]? = nil
    private(set) var newPasswordObfuscator: [UInt8]? = nil
    let mode: UInt32

    mutating func setPassword(_ value: String) {
        self.passwordObfuscator = self.getObfuscator(for: value)
        guard let passwordObfuscator else {
            preconditionFailure()
        }
        self.password = self.xorBytes(value.bytes, passwordObfuscator)
    }

    mutating func setNewPassword(_ value: String) {
        self.newPasswordObfuscator = self.getObfuscator(for: value)
        guard let newPasswordObfuscator else {
            preconditionFailure()
        }
        self.newPassword = self.xorBytes(value.bytes, newPasswordObfuscator)
    }

    func getPassword() -> [UInt8]? {
        guard let password, let passwordObfuscator else { return nil }
        let pw = xorBytes(password, passwordObfuscator)
        return pw
    }

    func getNewPassword() -> [UInt8]? {
        guard let newPassword, let newPasswordObfuscator else { return nil }
        return xorBytes(newPassword, newPasswordObfuscator)
    }

    /// Perform an XOR of two byte arrays as a means of obfuscating a password
    /// that is stored on the structure. It is assumed that the byte arrays are of
    /// the same length.
    private func xorBytes(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        let length = a.count
        var result = [UInt8](repeating: 0, count: length)
        for i in 0..<length {
            result[i] = a[i] ^ b[i]
        }
        return result
    }

    private func getObfuscator(for value: String) -> [UInt8] {
        return [UInt8].random(count: value.lengthOfBytes(using: .utf8))
    }
}

struct Description {
//    var addressLists = []
    var tcpConnectTimeout = DEFAULT_TCP_CONNECT_TIMEOUT
    var sslServerDNMatch = true
    var purity: Purity = .default
    var serviceName: String
}

struct Address {}
struct DescriptionList {}

// MARK: TNSNamesFile

struct TNSNamesFile {
    let file: URL
    let timestamp: Date
    var entries: [String: String]

    /// Read and parse the file and retain the connect descriptors found inside the file.
    mutating func read() {
        do {
            let file = try String(contentsOf: file)
            var entryNames: [String]?
            var entryLines = [String]()
            var numParens = 0
            for line in file.components(separatedBy: .newlines) {
                var line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pos = line.firstIndex(of: "#") {
                    line = String(line[..<pos])
                }
                guard !line.isEmpty else { continue }
                if entryNames == nil {
                    if let pos = line.firstIndex(of: "=") {
                        entryNames = line[..<pos].split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                        line = String(line[line.index(after: pos)...])
                    } else {
                        continue
                    }
                }
                if !line.isEmpty {
                    numParens += line.filter { $0 == "(" }.count - line.filter { $0 == ")" }.count
                    entryLines.append(line)
                }
                if !entryLines.isEmpty && numParens <= 0, let names = entryNames {
                    let descriptor = entryLines.joined()
                    for name in names {
                        self.entries[name.uppercased()] = descriptor
                    }
                    entryNames = nil
                }
            }
        } catch {
            print("Error reading file: \(error)")
        }
    }
}
