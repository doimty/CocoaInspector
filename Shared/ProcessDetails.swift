import Foundation

enum ProcessDetailKind: UInt64, Codable, CaseIterable, Sendable {
    case summary = 1
    case threads = 2
    case files = 3
    case ports = 4
    case modules = 5
}

enum CollectorStatus: String, Codable, Sendable {
    case available
    case partial
    case unsupported
    case permissionDenied
    case processExited
    case failed
}

struct ThreadRecord: Codable, Equatable, Sendable {
    let id: UInt64
    let userTime: UInt64
    let systemTime: UInt64
    let cpuUsage: Int32
    let policy: Int32
    let runState: Int32
    let flags: Int32
    let sleepTime: Int32
    let currentPriority: Int32
    let basePriority: Int32
    let maximumPriority: Int32
    let name: String
}

enum FileDescriptorKind: UInt32, Codable, Sendable {
    case vnode = 1
    case socket = 2
    case kqueue = 5
    case pipe = 6
}

struct FileDescriptorRecord: Codable, Equatable, Sendable {
    let descriptor: Int32
    let kind: FileDescriptorKind
    var openFlags: UInt32 = 0
    var status: UInt32 = 0
    var object: UInt64 = 0
    var peer: UInt64 = 0
    var path = ""
    var localAddress = ""
    var remoteAddress = ""
    var detail = ""
}

struct MachPortRecord: Codable, Equatable, Sendable {
    let name: UInt32
    let rights: UInt32
    let userReferences: UInt32
    let object: UInt32
    let objectType: UInt32
    let setMembers: [UInt32]
}

struct ModuleRecord: Codable, Equatable, Sendable {
    let path: String
    let identifier: String
    let address: UInt64
    let size: UInt64
    let referenceCount: UInt32
}

struct BundleMetadata: Codable, Equatable, Sendable {
    let identifier: String
    let name: String
    let displayName: String
    let version: String
    let minimumOSVersion: String
    let SDKName: String
    let platformVersion: String
    let compiler: String
}

struct ProcessDetailSnapshot: Codable, Equatable, Sendable {
    let identity: ProcessIdentity
    let kind: ProcessDetailKind
    let status: CollectorStatus
    let errorCode: Int32
    var process: ProcessRecord?
    var threads: [ThreadRecord] = []
    var files: [FileDescriptorRecord] = []
    var ports: [MachPortRecord] = []
    var modules: [ModuleRecord] = []
    var bundle: BundleMetadata?
}
