import SwiftUI
import Darwin
import NetworkExtension

let MIHOMO_CANDIDATES = [
    "/var/jb/usr/local/bin/mihomo",
    "/var/jb/usr/bin/mihomo",
    "/usr/local/bin/mihomo",
    "/usr/bin/mihomo",
    "/opt/procursus/bin/mihomo",
]

let TUNNEL_BUNDLE_ID = "com.metacubex.mihomo-toggle.tunnel"

func resolveConfigDir() -> String {
    let fm = FileManager.default
    var candidates: [String] = []
    for root in findJailbreakRoots() {
        candidates.append(root + "/var/mobile/.config/mihomo")
        candidates.append(root + "/.config/mihomo")
    }
    candidates.append("/var/mobile/.config/mihomo")
    for c in candidates {
        if (try? fm.contentsOfDirectory(atPath: c)) != nil {
            return c
        }
    }
    return "/var/mobile/.config/mihomo"
}

var CONFIG_DIR: String { resolveConfigDir() }
var PID_PATH: String { CONFIG_DIR + "/.mihomo.pid" }
var CFG_PATH: String { CONFIG_DIR + "/.config_path" }
var LOG_PATH: String { CONFIG_DIR + "/mihomo.log" }

func configCwd() -> String {
    let d = resolveConfigDir()
    let suffix = "/.config/mihomo"
    if d.hasSuffix(suffix) {
        return String(d.dropLast(suffix.count))
    }
    return d
}

func findJailbreakRoots() -> [String] {
    var roots: [String] = []
    let fm = FileManager.default
    if fm.fileExists(atPath: "/var/jb") {
        roots.append("/var/jb")
    }
    for base in ["/var/containers/Bundle/Application",
                 "/private/var/containers/Bundle/Application",
                 "/var/containers/Shared/SystemGroup/systemgroup.com.apple.containerd",
                 "/private/var/mobile/Containers/Shared/AppGroup"] {
        guard let entries = try? fm.contentsOfDirectory(atPath: base) else { continue }
        for name in entries {
            if name.hasPrefix(".jbroot-") {
                roots.append(base + "/" + name)
            }
            if name.hasPrefix("jbroot-") {
                roots.append(base + "/" + name)
            }
        }
    }
    return roots
}

func findMihomoBinary() -> String {
    var candidates = MIHOMO_CANDIDATES
    let fm = FileManager.default
    for root in findJailbreakRoots() {
        for sub in ["/usr/local/bin/mihomo", "/usr/bin/mihomo", "/usr/local/bin/mihomo-ios"] {
            candidates.append(root + sub)
        }
    }
    for p in candidates {
        if fm.isExecutableFile(atPath: p) {
            return p
        }
    }
    return ""
}

func probeCandidates() -> String {
    var lines: [String] = []
    let fm = FileManager.default
    for root in findJailbreakRoots() {
        lines.append("jbroot: \(root)")
        for sub in ["/usr/local/bin/mihomo", "/usr/bin/mihomo"] {
            lines.append("  \(root + sub): \(fm.isExecutableFile(atPath: root + sub) ? "OK" : "missing")")
        }
    }
    for p in MIHOMO_CANDIDATES {
        lines.append("\(p): \(fm.isExecutableFile(atPath: p) ? "OK" : "missing")")
    }
    return lines.joined(separator: "\n")
}

func readPid() -> pid_t {
    guard let s = try? String(contentsOfFile: PID_PATH, encoding: .utf8) else { return 0 }
    return pid_t(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

func processAlive(_ pid: pid_t) -> Bool {
    if pid <= 0 { return false }
    return kill(pid, 0) == 0
}

func stopMihomo() {
    let pid = readPid()
    if pid > 0 {
        kill(pid, SIGTERM)
        for _ in 0..<20 {
            if !processAlive(pid) { break }
            usleep(100_000)
        }
        if processAlive(pid) {
            kill(pid, SIGKILL)
        }
    }
    try? FileManager.default.removeItem(atPath: PID_PATH)
}

var lastSpawnError = ""

@discardableResult
func startMihomo(configPath: String) -> pid_t {
    stopMihomo()
    usleep(200_000)

    let binPath = findMihomoBinary()
    guard !binPath.isEmpty else {
        lastSpawnError = "未找到 mihomo 二进制。探测结果:\n" + probeCandidates()
        return 0
    }

    let relConfig = ".config/mihomo/" + ((configPath as NSString).lastPathComponent)
    let cwdPath = configCwd()
    let bin = findMihomoBinary()
    let roots = findJailbreakRoots()
    let fm = FileManager.default
    var probeLines = "roots:\n"
    for r in roots {
        probeLines += "  \(r)\n"
        for sub in ["/var/mobile/.config/mihomo", "/.config/mihomo"] {
            probeLines += "    \(r + sub): \((try? fm.contentsOfDirectory(atPath: r + sub)) != nil ? "OK" : "missing")\n"
        }
    }
    probeLines += "configDir: \(resolveConfigDir())\ncwd: \(cwdPath)\nbin: \(bin)\n"
    let cmdLine = "=== mihomo start ===\n" + probeLines + "cmd: -d .config/mihomo -f \(relConfig)\n"
    if let f = fopen(LOG_PATH, "a") {
        fputs(cmdLine, f)
        fclose(f)
    }

    let argv: [UnsafeMutablePointer<CChar>?] = [
        strdup(binPath),
        strdup("-d"),
        strdup(".config/mihomo"),
        strdup("-f"),
        strdup(relConfig),
        nil
    ]
    defer {
        for p in argv { if let p = p { free(p) } }
    }

    let logFD = open(LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    var fileActions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&fileActions)
    if logFD >= 0 {
        posix_spawn_file_actions_adddup2(&fileActions, logFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, logFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, logFD)
    }
    if !cwdPath.isEmpty && chdir(cwdPath) != 0 {
        let err = String(cString: strerror(errno))
        lastSpawnError = "chdir 到 \(cwdPath) 失败: \(err)"
        posix_spawn_file_actions_destroy(&fileActions)
        return 0
    }

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))

    var pid: pid_t = 0
    errno = 0
    let rc = posix_spawn(&pid, binPath, &fileActions, &attr, argv, nil)
    if rc == 0 && pid > 0 {
        try? Data("\(pid)".utf8).write(to: URL(fileURLWithPath: PID_PATH))
        return pid
    }
    let errDesc = rc != 0 ? String(cString: strerror(rc)) : (errno != 0 ? String(cString: strerror(errno)) : "unknown error")
    lastSpawnError = "posix_spawn 失败: \(errDesc)"
    posix_spawn_file_actions_destroy(&fileActions)
    posix_spawnattr_destroy(&attr)
    return 0
}

@main
struct MihomoToggleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

var tunnelManager: NETunnelProviderManager?

func loadTunnelManager(completion: @escaping (NETunnelProviderManager?) -> Void) {
    NETunnelProviderManager.loadAllFromPreferences { managers, _ in
        var match = managers?.first {
            $0.protocolConfiguration is NETunnelProviderProtocol &&
            $0.localizedDescription == "mihomo 全局代理"
        }
        if match == nil {
            let m = NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = TUNNEL_BUNDLE_ID
            proto.serverAddress = "mihomo"
            proto.disconnectOnSleep = false
            m.protocolConfiguration = proto
            m.localizedDescription = "mihomo 全局代理"
            m.isEnabled = true
            m.saveToPreferences { _ in
                match = m
                tunnelManager = m
                completion(m)
            }
        } else {
            tunnelManager = match
            completion(match)
        }
    }
}

struct ContentView: View {
    @State private var status = "unknown"
    @State private var busy = false
    @State private var selectedConfig = ""
    @State private var configs: [String] = []
    @State private var lastError = ""
    @State private var showLog = false
    @State private var vpnStatus: NEVPNStatus = .invalid
    @State private var masterDesired = false

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private var masterOnBinding: Binding<Bool> {
        Binding(
            get: { self.masterDesired },
            set: { newValue in
                self.masterDesired = newValue
                if newValue {
                    self.toggleMasterOn()
                } else {
                    self.toggleMasterOff()
                }
            }
        )
    }

    private var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("mihomo")
                .font(.system(size: 34, weight: .bold))

            if !selectedConfig.isEmpty {
                Text("当前配置: \(selectedConfig)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            ZStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 120, height: 120)
                if busy {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                } else {
                    Text(statusText)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                }
            }

            HStack(spacing: 14) {
                Text("总开关")
                    .font(.system(size: 18, weight: .semibold))
                Toggle("", isOn: masterOnBinding)
                    .labelsHidden()
                    .scaleEffect(1.4)
                    .frame(width: 80)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .background(Color(.systemGray6))
            .cornerRadius(12)

            if !lastError.isEmpty {
                Text(lastError)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            VStack(spacing: 12) {
                Text("配置切换")
                    .font(.headline)

                Picker("配置", selection: $selectedConfig) {
                    ForEach(configs, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(MenuPickerStyle())
                .frame(maxWidth: 240)
                .disabled(masterOn)
                .onChange(of: selectedConfig) { newValue in
                    applyConfig(newValue)
                }

                HStack(spacing: 8) {
                    Text("mihomo")
                    Circle()
                        .fill(status == "running" ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Spacer()
                    Text("VPN")
                    Circle()
                        .fill(vpnColor)
                        .frame(width: 8, height: 8)
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Divider()
                    .padding(.vertical, 4)

                Button("查看运行日志") {
                    showLog = true
                }
                .font(.footnote)

                Text("目录: \(CONFIG_DIR)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .onReceive(timer) { _ in
            refreshStatus()
        }
        .onAppear {
            loadConfigs()
            refreshStatus()
            loadTunnelManager { _ in
                self.refreshVpnStatus()
            }
        }
        .sheet(isPresented: $showLog) {
            LogView()
        }
    }

    private var statusColor: Color {
        if status == "running" {
            return vpnStatus == .connected ? .green : .orange
        }
        return status == "stopped" ? .gray : .orange
    }

    private var statusText: String {
        if status == "running" {
            return vpnStatus == .connected ? "已连接" : "连接中"
        }
        return status == "stopped" ? "已停止" : "未知"
    }

    private var vpnColor: Color {
        switch vpnStatus {
        case .connected: return .green
        case .connecting, .disconnecting, .reasserting: return .orange
        default: return .gray
        }
    }

    private func loadConfigs() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: CONFIG_DIR) else {
            lastError = "无法读取配置目录 \(CONFIG_DIR)"
            return
        }
        configs = files
            .filter { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }
            .sorted()
        if let cur = try? String(contentsOfFile: CFG_PATH, encoding: .utf8) {
            let name = (cur as NSString).lastPathComponent
            if configs.contains(name) {
                selectedConfig = name
                return
            }
        }
        if configs.contains("baidu.yaml") {
            selectedConfig = "baidu.yaml"
        } else if let first = configs.first {
            selectedConfig = first
        }
    }

    private func currentConfigPath() -> String {
        if !selectedConfig.isEmpty {
            return CONFIG_DIR + "/" + selectedConfig
        }
        return CONFIG_DIR + "/baidu.yaml"
    }

    private func applyConfig(_ name: String) {
        guard !name.isEmpty else { return }
        do {
            try Data((CONFIG_DIR + "/" + name).utf8).write(to: URL(fileURLWithPath: CFG_PATH))
            lastError = "已切换到 \(name)"
        } catch {
            lastError = "写入配置失败: \(error.localizedDescription)"
            return
        }
        if status == "running" {
            restart()
        }
    }

    private func toggleMasterOn() {
        busy = true
        lastError = ""
        if status != "running" {
            let pid = startMihomo(configPath: currentConfigPath())
            if pid <= 0 {
                lastError = lastSpawnError.isEmpty ? "启动失败" : lastSpawnError
                busy = false
                refreshStatus()
                return
            }
            lastError = "mihomo 已启动 (pid \(pid))"
        }
        loadTunnelManager { manager in
            guard let manager = manager else {
                self.lastError = "创建 VPN 配置失败"
                self.busy = false
                self.refreshStatus()
                return
            }
            manager.isEnabled = true
            manager.saveToPreferences { error in
                if let error = error {
                    self.lastError = "保存 VPN 配置失败: \(error.localizedDescription)"
                    self.busy = false
                    self.refreshStatus()
                    return
                }
                do {
                    try manager.connection.startVPNTunnel()
                    self.lastError = "已开启"
                } catch {
                    self.lastError = "启动 VPN 失败: \(error.localizedDescription)"
                }
                self.busy = false
                self.refreshStatus()
            }
        }
    }

    private func toggleMasterOff() {
        busy = true
        lastError = ""
        tunnelManager?.connection.stopVPNTunnel()
        NEVPNManager.shared().connection.stopVPNTunnel()
        stopMihomo()
        busy = false
        refreshStatus()
    }

    private func restart() {
        busy = true
        lastError = ""
        let pid = startMihomo(configPath: currentConfigPath())
        if pid > 0 {
            lastError = "mihomo 已用新配置重启 (pid \(pid))"
        } else {
            lastError = lastSpawnError.isEmpty ? "重启失败" : lastSpawnError
        }
        refreshStatus()
        busy = false
    }

    private func refreshStatus() {
        let running = processAlive(readPid())
        status = running ? "running" : "stopped"
        refreshVpnStatus()
        if !busy {
            let vpnUp = (vpnStatus == .connected || vpnStatus == .connecting || vpnStatus == .reasserting)
            masterDesired = running && vpnUp
        }
    }

    private func refreshVpnStatus() {
        if let m = tunnelManager {
            vpnStatus = m.connection.status
        } else {
            vpnStatus = NEVPNManager.shared().connection.status
        }
    }
}

struct LogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""

    var body: some View {
        NavigationView {
            ScrollView {
                Text(content.isEmpty ? "(日志为空)" : content)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("mihomo.log")
            .navigationBarItems(trailing: Button("完成") {
                dismiss()
            })
        }
        .onAppear {
            content = (try? String(contentsOfFile: LOG_PATH, encoding: .utf8)) ?? "(读取失败)"
        }
    }
}
