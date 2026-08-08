import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {

    private let logPath = "/var/mobile/.config/mihomo/tunnel.log"

    private func log(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        NSLog("%@", msg)
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath) {
                if let fh = FileHandle(forWritingAtPath: logPath) {
                    fh.seekToEndOfFile()
                    fh.write(data)
                    try? fh.close()
                }
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        log("startTunnel called, pid=\(getpid())")
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "192.168.20.1")
        settings.mtu = 1500

        let ipv4 = NEIPv4Settings(addresses: ["192.168.20.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = []
        ipv4.excludedRoutes = []
        settings.ipv4Settings = ipv4

        let proxy = NEProxySettings()
        proxy.httpEnabled = true
        proxy.httpServer = NEProxyServer(address: "127.0.0.1", port: 7890)
        proxy.httpsEnabled = true
        proxy.httpsServer = NEProxyServer(address: "127.0.0.1", port: 7890)
        proxy.matchDomains = [""]
        settings.proxySettings = proxy

        setTunnelNetworkSettings(settings) { error in
            if let error = error {
                self.log("setTunnelNetworkSettings failed: \(error)")
            } else {
                self.log("setTunnelNetworkSettings ok")
            }
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log("stopTunnel reason=\(reason.rawValue)")
        completionHandler()
    }
}
