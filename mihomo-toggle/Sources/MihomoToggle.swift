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

func configDirCandidates() -> [String] {
    var candidates: [String] = []
    for root in findJailbreakRoots() {
        candidates.append(root + "/var/mobile/.config/mihomo")
        candidates.append(root + "/.config/mihomo")
    }
    candidates.append("/var/mobile/.config/mihomo")
    candidates.append("/var/jb/var/mobile/.config/mihomo")
    candidates.append("/var/jb/.config/mihomo")
    var seen = Set<String>()
    return candidates.filter { seen.insert($0).inserted }
}

private var _resolvedConfigDir: String?

func resolveConfigDir() -> String {
    let fm = FileManager.default
    if let cached = _resolvedConfigDir, (try? fm.contentsOfDirectory(atPath: cached)) != nil {
        return cached
    }
    _resolvedConfigDir = nil
    let candidates = configDirCandidates()
    for c in candidates {
        if let files = try? fm.contentsOfDirectory(atPath: c),
           files.contains(where: { $0.hasSuffix(".yaml") || $0.hasSuffix(".yml") }) {
            _resolvedConfigDir = c
            return c
        }
    }
    for c in candidates {
        if (try? fm.contentsOfDirectory(atPath: c)) != nil {
            _resolvedConfigDir = c
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
    if !_jbRoots.isEmpty { return _jbRoots }
    let fm = FileManager.default
    if fm.fileExists(atPath: "/var/jb") {
        _jbRoots = ["/var/jb"]
        return _jbRoots
    }
    for base in ["/var/containers/Bundle/Application",
                 "/private/var/containers/Bundle/Application",
                 "/var/containers/Shared/SystemGroup/systemgroup.com.apple.containerd",
                 "/private/var/mobile/Containers/Shared/AppGroup"] {
        guard let entries = try? fm.contentsOfDirectory(atPath: base) else { continue }
        for name in entries {
            if name.hasPrefix(".jbroot-") {
                _jbRoots.append(base + "/" + name)
            }
            if name.hasPrefix("jbroot-") {
                _jbRoots.append(base + "/" + name)
            }
        }
    }
    return _jbRoots
}

private var _jbRoots: [String] = []

private var _cachedBinary = ""
private var _binarySearched = false

func findMihomoBinary() -> String {
    if _binarySearched { return _cachedBinary }
    _binarySearched = true
    var candidates = MIHOMO_CANDIDATES
    let fm = FileManager.default
    for root in findJailbreakRoots() {
        for sub in ["/usr/local/bin/mihomo", "/usr/bin/mihomo", "/usr/local/bin/mihomo-ios"] {
            candidates.append(root + sub)
        }
    }
    for p in candidates {
        if fm.isExecutableFile(atPath: p) {
            _cachedBinary = p
            break
        }
    }
    return _cachedBinary
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
        for _ in 0..<40 {
            if !processAlive(pid) { break }
            usleep(25_000)
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
    let roots = findJailbreakRoots()
    let fm = FileManager.default
    var probeLines = "roots:\n"
    for r in roots {
        probeLines += "  \(r)\n"
    }
    for c in configDirCandidates() {
        probeLines += "  \(c): \((try? fm.contentsOfDirectory(atPath: c)) != nil ? "OK" : "missing")\n"
    }
    probeLines += "configDir: \(resolveConfigDir())\ncwd: \(cwdPath)\nbin: \(binPath)\n"
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
        let done: (NETunnelProviderManager?) -> Void = { m in
            DispatchQueue.main.async { completion(m) }
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
                done(m)
            }
        } else {
            tunnelManager = match
            done(match)
        }
    }
}

struct ContentView: View {
    @State private var status = "unknown"
    @State private var busy = false
    @State private var selectedConfig = ""
    @State private var configs: [String] = []
    @State private var lastError = ""
    @State private var showEdit = false
    @State private var vpnStatus: NEVPNStatus = .invalid
    @State private var masterDesired = false

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.99, green: 0.99, blue: 1.0),
                    Color(red: 0.93, green: 0.95, blue: 0.99)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()

                VStack(spacing: 6) {
                    Text("MIHOMO")
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .tracking(6)
                        .foregroundColor(neonCyan)
                        .shadow(color: neonCyan.opacity(0.4), radius: 6)
                    if !selectedConfig.isEmpty {
                        Text("> 当前配置: \(selectedConfig)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(neonCyan.opacity(0.8))
                    }
                }

                Button {
                    masterDesired.toggle()
                    if masterDesired {
                        toggleMasterOn()
                    } else {
                        toggleMasterOff()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.gray.opacity(0.25), lineWidth: 10)
                            .frame(width: 150, height: 150)
                        Circle()
                            .trim(from: 0, to: ringProgress)
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [glowColor.opacity(0.3), glowColor, Color.gray.opacity(0.6)]),
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .frame(width: 150, height: 150)
                            .rotationEffect(.degrees(-90))
                            .shadow(color: glowColor.opacity(0.7), radius: 12)
                        VStack(spacing: 4) {
                            if busy {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: glowColor))
                                    .scaleEffect(1.3)
                            } else {
                                Text(statusText)
                                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                                    .foregroundColor(statusTextColor)
                                    .shadow(color: glowColor.opacity(0.5), radius: 5)
                                Text(statusCode)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.gray.opacity(0.6))
                            }
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(busy)

                if !lastError.isEmpty {
                    Text("⚠ \(lastError)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.red.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                VStack(spacing: 14) {
                    Text("// 配置切换")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundColor(neonCyan.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        Picker("配置", selection: $selectedConfig) {
                            ForEach(configs, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                        .font(.system(size: 13, design: .monospaced))
                        .tint(neonCyan)
                        .disabled(masterDesired)
                        .onChange(of: selectedConfig) { newValue in
                            applyConfig(newValue)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.gray.opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                        )

                        Button {
                            showEdit = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(neonCyan)
                                .frame(width: 40, height: 38)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(neonCyan.opacity(0.1))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(neonCyan.opacity(0.5), lineWidth: 1)
                                        )
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(selectedConfig.isEmpty)
                    }
                    .frame(maxWidth: 300)

                    HStack(spacing: 10) {
                        Text("MIHOMO")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(status == "running" ? neonGreen : .gray.opacity(0.6))
                        Circle()
                            .fill(status == "running" ? neonGreen : Color.gray)
                            .frame(width: 7, height: 7)
                            .shadow(color: status == "running" ? neonGreen.opacity(0.9) : .clear, radius: 4)
                        Spacer()
                        Text("VPN")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(vpnUp ? neonGreen : .gray.opacity(0.6))
                        Circle()
                            .fill(vpnUp ? neonGreen : Color.gray)
                            .frame(width: 7, height: 7)
                            .shadow(color: vpnUp ? neonGreen.opacity(0.9) : .clear, radius: 4)
                    }

                    Divider()
                        .background(Color.gray.opacity(0.3))
                        .padding(.vertical, 2)

                    Text("DIR: \(CONFIG_DIR)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                .padding(18)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color.white.opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 22)

                Spacer()
            }
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
        .sheet(isPresented: $showEdit) {
            ConfigEditorView(fileName: selectedConfig) { saved in
                if saved {
                    lastError = "配置已保存"
                    if status == "running" {
                        restart()
                    } else {
                        refreshStatus()
                    }
                }
            }
        }
    }

    private var neonCyan: Color { Color(red: 0.0, green: 0.55, blue: 0.72) }
    private var neonGreen: Color { Color(red: 0.0, green: 0.62, blue: 0.32) }

    private var glowColor: Color {
        if status == "running" {
            return vpnStatus == .connected ? neonGreen : Color(red: 0.85, green: 0.45, blue: 0.05)
        }
        return status == "stopped" ? Color.gray.opacity(0.45) : Color(red: 0.85, green: 0.45, blue: 0.05)
    }

    private var ringProgress: CGFloat {
        if status == "running" {
            return vpnStatus == .connected ? 1.0 : 0.7
        }
        return status == "stopped" ? 0.0 : 0.7
    }

    private var statusTextColor: Color {
        if status == "running" {
            return vpnStatus == .connected ? neonGreen : Color(red: 0.85, green: 0.45, blue: 0.05)
        }
        return status == "stopped" ? Color.gray.opacity(0.7) : Color(red: 0.85, green: 0.45, blue: 0.05)
    }

    private var statusCode: String {
        if status == "running" {
            return vpnStatus == .connected ? "[ONLINE]" : "[CONNECTING]"
        }
        return status == "stopped" ? "[OFFLINE]" : "[UNKNOWN]"
    }

    private var vpnUp: Bool {
        vpnStatus == .connected || vpnStatus == .connecting || vpnStatus == .reasserting
    }

    private var statusText: String {
        if status == "running" {
            return vpnStatus == .connected ? "已连接" : "连接中"
        }
        return status == "stopped" ? "已停止" : "未知"
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
        let needStart = status != "running"
        let startVPN: () -> Void = {
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
        if needStart {
            DispatchQueue.global(qos: .userInitiated).async {
                let pid = startMihomo(configPath: self.currentConfigPath())
                DispatchQueue.main.async {
                    if pid <= 0 {
                        self.lastError = lastSpawnError.isEmpty ? "启动失败" : lastSpawnError
                        self.busy = false
                        self.refreshStatus()
                        return
                    }
                    self.lastError = "mihomo 已启动 (pid \(pid))"
                    startVPN()
                }
            }
        } else {
            startVPN()
        }
    }

    private func toggleMasterOff() {
        busy = true
        lastError = ""
        tunnelManager?.connection.stopVPNTunnel()
        NEVPNManager.shared().connection.stopVPNTunnel()
        DispatchQueue.global(qos: .userInitiated).async {
            stopMihomo()
            DispatchQueue.main.async {
                self.busy = false
                self.refreshStatus()
            }
        }
    }

    private func restart() {
        busy = true
        lastError = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let pid = startMihomo(configPath: self.currentConfigPath())
            DispatchQueue.main.async {
                if pid > 0 {
                    self.lastError = "mihomo 已用新配置重启 (pid \(pid))"
                } else {
                    self.lastError = lastSpawnError.isEmpty ? "重启失败" : lastSpawnError
                }
                self.refreshStatus()
                self.busy = false
            }
        }
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

struct ConfigEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let fileName: String
    var onSaved: (Bool) -> Void

    @State private var content = ""
    @State private var original = ""
    @State private var saveError = ""

    var body: some View {
        ZStack {
            Color(red: 0.96, green: 0.97, blue: 0.99)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    Circle().fill(Color.orange).frame(width: 10, height: 10)
                    Circle().fill(Color.green).frame(width: 10, height: 10)
                    Spacer()
                    Text("vim — \(fileName)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.8))
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text("取消")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white)

                TextEditor(text: $content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Color(red: 0.15, green: 0.17, blue: 0.2))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .background(Color(red: 0.96, green: 0.97, blue: 0.99))
                    .padding(8)

                if !saveError.isEmpty {
                    Text("⚠ \(saveError)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                }

                HStack(spacing: 12) {
                    Text("\(fileName) — \(content.count) 字符")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.7))
                    Spacer()
                    Button {
                        content = original
                    } label: {
                        Label("还原", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.orange)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.orange.opacity(0.15))
                            )
                    }
                    Button {
                        save()
                    } label: {
                        Label("保存", systemImage: "checkmark")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(neonGreen)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(neonGreen.opacity(0.15))
                            )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.white)
            }
        }
        .onAppear {
            load()
        }
    }

    private var neonGreen: Color { Color(red: 0.0, green: 0.62, blue: 0.32) }

    private var filePath: String {
        if fileName.isEmpty { return "" }
        return CONFIG_DIR + "/" + fileName
    }

    private func load() {
        original = (try? String(contentsOfFile: filePath, encoding: .utf8)) ?? ""
        content = original
    }

    private func save() {
        saveError = ""
        guard !filePath.isEmpty else {
            saveError = "未选择配置文件"
            return
        }
        do {
            try Data(content.utf8).write(to: URL(fileURLWithPath: filePath))
            original = content
            onSaved(true)
            dismiss()
        } catch {
            saveError = "保存失败: \(error.localizedDescription)"
            onSaved(false)
        }
    }
}
