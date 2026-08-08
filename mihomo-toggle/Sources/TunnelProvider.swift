import NetworkExtension
import Foundation

class PacketTunnelProvider: NEPacketTunnelProvider {

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
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
        proxy.matchDomains = []
        settings.proxySettings = proxy

        setTunnelNetworkSettings(settings) { error in
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
