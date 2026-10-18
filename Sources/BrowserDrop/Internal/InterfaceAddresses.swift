import Foundation
import Network

/// The addresses a computer on the same network can open the page at.
enum InterfaceAddresses {
  struct Entry: Equatable {
    let name: String
    let ipv4: String
  }

  /// What `NWPathMonitor` says an interface is. Hotspot bridges aren't on the path, so they stay unknown.
  enum PathKind: Equatable {
    case wifi, wired, cellular, other

    init(_ type: NWInterface.InterfaceType) {
      switch type {
      case .wifi: self = .wifi
      case .wiredEthernet: self = .wired
      case .cellular: self = .cellular
      default: self = .other
      }
    }
  }

  /// Interfaces that never reach a computer on the local network: cellular, VPN and tunnels,
  /// AirDrop/Wi‑Fi Aware peer links.
  private static let excludedPrefixes = ["pdp_ip", "utun", "ipsec", "ppp", "awdl", "llw", "gif", "stf", "anpi"]

  /// IPv4 addresses of every interface that is up, except loopback.
  static func current() -> [Entry] {
    var result: [Entry] = []
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return result }
    defer { freeifaddrs(first) }

    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
      let flags = Int32(pointer.pointee.ifa_flags)
      guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
        let address = pointer.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
      else { continue }
      var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
      else { continue }
      let ipv4 = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      result.append(Entry(name: String(cString: pointer.pointee.ifa_name), ipv4: ipv4))
    }
    return result
  }

  /// What a computer would use the address for, or `nil` when no computer on the network can reach it.
  ///
  /// Interface names aren't API (`en0` isn't always Wi‑Fi), so the path monitor's view wins when it has one.
  static func kind(of entry: Entry, pathKinds: [String: PathKind]) -> BrowserDropServer.Address.Kind? {
    if entry.ipv4.hasPrefix("127.") || entry.ipv4.hasPrefix("169.254.") { return nil }
    if excludedPrefixes.contains(where: { entry.name.hasPrefix($0) }) { return nil }
    switch pathKinds[entry.name] {
    case .wifi: return .wifi
    case .wired: return .wired
    case .cellular: return nil
    case .other, nil: return entry.name.hasPrefix("bridge") ? .hotspot : .other
    }
  }

  static func addresses(
    entries: [Entry],
    pathKinds: [String: PathKind],
    port: UInt16
  ) -> [BrowserDropServer.Address] {
    let addresses = entries.compactMap { entry -> BrowserDropServer.Address? in
      guard let kind = kind(of: entry, pathKinds: pathKinds) else { return nil }
      return BrowserDropServer.Address(kind: kind, interfaceName: entry.name, host: entry.ipv4, port: port)
    }
    return addresses.sorted { lhs, rhs in
      lhs.kind.sortOrder != rhs.kind.sortOrder
        ? lhs.kind.sortOrder < rhs.kind.sortOrder
        : lhs.interfaceName < rhs.interfaceName
    }
  }
}

extension BrowserDropServer.Address.Kind {
  fileprivate var sortOrder: Int {
    switch self {
    case .wifi: 0
    case .wired: 1
    case .hotspot: 2
    case .other: 3
    }
  }
}
