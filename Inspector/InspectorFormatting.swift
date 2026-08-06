import Foundation

enum InspectorLocalization {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    static func format(_ key: String, _ argument: CVarArg) -> String {
        String.localizedStringWithFormat(text(key), argument)
    }

    static func format(_ key: String, _ first: CVarArg, _ second: CVarArg) -> String {
        String.localizedStringWithFormat(text(key), first, second)
    }
}

enum InspectorFormat {
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    static func percent(_ fraction: Double) -> String {
        String(format: "%.1f%%", fraction * 100)
    }

    static func cpuTime(_ ticks: UInt64, numerator: UInt32, denominator: UInt32) -> String {
        guard denominator != 0, numerator != 0 else { return "—" }
        let seconds = Double(ticks) * Double(numerator) / Double(denominator) / 1_000_000_000
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let total = Int(seconds)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    static func duration(_ nanoseconds: UInt64) -> String {
        let total = Int(nanoseconds / 1_000_000_000)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return InspectorLocalization.format("%lldd %lldh", Int64(days), Int64(hours))
        }
        if hours > 0 {
            return InspectorLocalization.format("%lldh %lldm", Int64(hours), Int64(minutes))
        }
        return InspectorLocalization.format("%lldm", Int64(minutes))
    }

    static func user(_ uid: UInt32) -> String {
        switch uid {
        case 0: "root"
        case 501: "mobile"
        default: "uid \(uid)"
        }
    }

    static func sandbox(_ status: ProcessSandboxStatus) -> String {
        switch status {
        case .unavailable: InspectorLocalization.text("Unknown")
        case .unrestricted: InspectorLocalization.text("Unrestricted")
        case .sandboxed: InspectorLocalization.text("Sandboxed")
        }
    }

    static func threadState(_ runState: Int32) -> String {
        switch runState {
        case 1: InspectorLocalization.text("Running")
        case 2: InspectorLocalization.text("Stopped")
        case 3: InspectorLocalization.text("Waiting")
        case 4: InspectorLocalization.text("Uninterruptible")
        case 5: InspectorLocalization.text("Halted")
        default: InspectorLocalization.format("State %lld", Int64(runState))
        }
    }

    static func fileKind(_ kind: FileDescriptorKind) -> String {
        switch kind {
        case .vnode: InspectorLocalization.text("File")
        case .socket: InspectorLocalization.text("Socket")
        case .kqueue: InspectorLocalization.text("Kqueue")
        case .pipe: InspectorLocalization.text("Pipe")
        }
    }

    static func portRights(_ rights: UInt32) -> String {
        var parts = [String]()
        if rights & 0x10000 != 0 { parts.append("send") }
        if rights & 0x20000 != 0 { parts.append("receive") }
        if rights & 0x40000 != 0 { parts.append("send-once") }
        if rights & 0x80000 != 0 { parts.append("port-set") }
        if rights & 0x100000 != 0 { parts.append("dead") }
        return parts.isEmpty ? hex(UInt64(rights)) : parts.joined(separator: ", ")
    }

    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    // Marketing version plus build, the way a bug report should quote it.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "v\(version)(\(build))"
    }
}

enum InspectorErrorText {
    static func describe(_ error: Error) -> String {
        guard let error = error as? InspectorDataError else {
            return InspectorLocalization.text("Something unexpected went wrong.")
        }
        switch error {
        case .disconnected:
            return InspectorLocalization.text("Lost the connection to the inspector service.")
        case .alreadyActive:
            return InspectorLocalization.text("This session is already running.")
        case .busy:
            return InspectorLocalization.text("Another request is still finishing.")
        case .invalidReply:
            return InspectorLocalization.text("The inspector service sent an unexpected reply.")
        case .transportFailure:
            return InspectorLocalization.text("Couldn’t reach the inspector service.")
        case .malformedSnapshot:
            return InspectorLocalization.text("The process data couldn’t be read.")
        case .rejected(let code):
            switch code {
            case .success:
                return InspectorLocalization.text("Done.")
            case .invalidRequest:
                return InspectorLocalization.text("The inspector service turned down this request.")
            case .foregroundLeaseRequired:
                return InspectorLocalization.text("The session timed out. Please try again.")
            case .busy:
                return InspectorLocalization.text("The inspector service is busy right now.")
            case .targetChanged:
                return InspectorLocalization.text("This process has ended or changed.")
            case .ticketExpired:
                return InspectorLocalization.text("That took too long. Please try again.")
            case .operationFailed:
                return InspectorLocalization.text("The inspector service couldn’t complete this.")
            }
        }
    }
}
