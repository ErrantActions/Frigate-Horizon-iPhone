import Foundation
import Darwin
import HorizonCore

enum LocalServerAddressLookup {
    static func resolve(_ address: ServerAddress) async throws -> [String] {
        guard let name = address.url.host else { throw HorizonError.invalidAddress }
        let host = name.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let lookup = Task.detached(priority: .utility) { () throws -> [String] in
            try Task.checkCancellation()
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var head: UnsafeMutablePointer<addrinfo>?
            let status = getaddrinfo(host, nil, &hints, &head)
            guard status == 0 else {
                throw HorizonError.message("DNS lookup failed (\(status)). Check the hostname and network, or enter a local address manually.")
            }
            defer { if let head { freeaddrinfo(head) } }
            var current = head
            var results: Set<String> = []
            while let entry = current {
                try Task.checkCancellation()
                guard let socketAddress = entry.pointee.ai_addr else {
                    throw HorizonError.message("DNS returned an unreadable address.")
                }
                var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let capacity = socklen_t(name.count)
                let result = getnameinfo(socketAddress, entry.pointee.ai_addrlen,
                    &name, capacity, nil, 0, NI_NUMERICHOST)
                guard result == 0 else { throw HorizonError.message("The DNS address could not be read (\(result)).") }
                let ip = String(cString: name)
                if LocalServerAddress.isPrivateIP(ip) { results.insert(ip) }
                current = entry.pointee.ai_next
            }
            guard !results.isEmpty else {
                throw HorizonError.message("This hostname did not resolve to a private address on this network. Enter the local address manually; no LAN scan was performed.")
            }
            return results.sorted()
        }
        return try await withTaskCancellationHandler {
            try await lookup.value
        } onCancel: { lookup.cancel() }
    }
}
