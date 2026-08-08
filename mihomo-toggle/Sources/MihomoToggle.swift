import SwiftUI
import Darwin

let MIHOMO_CANDIDATES = [
    "/var/jb/usr/local/bin/mihomo",
    "/var/jb/usr/bin/mihomo",
    "/usr/local/bin/mihomo",
    "/usr/bin/mihomo",
    "/opt/procursus/bin/mihomo",
]

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

struct ProxyGroupInfo: Identifiable {
    let id = UUID()
    let name: String
    let now: String
    let all: [String]
}

func controllerEndpoint(configDir: String) -> (port: String, secret: String) {
    let cfg = CFG_PATH
    guard let content = try? String(contentsOfFile: cfg, encoding: .utf8) else {
        return ("9090", "")
    }
    let current = (content as NSString).lastPathComponent
    guard let yaml = try? String(contentsOfFile: configDir + "/" + current, encoding: .utf8) else {
        return ("9090", "")
    }
    var port = "9090"
    var secret = ""
    for line in yaml.components(separatedBy: .newlines) {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("external-controller:") {
            let v = t.replacingOccurrences(of: "external-controller:", with: "").trimmingCharacters(in: .whitespaces)
            if let last = v.split(separator: ":").last {
                port = String(last)
            }
        } else if t.hasPrefix("secret:") {
            let v = t.replacingOccurrences(of: "secret:", with: "").trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
            if !v.isEmpty {
                secret = v
            }
        }
    }
    return (port, secret)
}

func fetchProxyGroups(configDir: String) -> [ProxyGroupInfo] {
    let (port, secret) = controllerEndpoint(configDir: configDir)
    let url = URL(string: "http://127.0.0.1:\(port)/proxies")!
    var req = URLRequest(url: url)
    req.timeoutInterval = 3
    if !secret.isEmpty {
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
    }
    let sem = DispatchSemaphore(value: 0)
    var result: [ProxyGroupInfo] = []
    URLSession.shared.dataTask(with: req) { data, _, _ in
        defer { sem.signal() }
        guard let data = data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = obj["proxies"] as? [String: Any] else { return }
        for (name, info) in proxies {
            guard let d = info as? [String: Any],
                  let type = d["type"] as? String, type == "Selector",
                  let all = d["all"] as? [String] else { continue }
            let now = (d["now"] as? String) ?? ""
            result.append(ProxyGroupInfo(name: name, now: now, all: all))
        }
    }.resume()
    _ = sem.wait(timeout: .now() + 4)
    return result.sorted { $0.name < $1.name }
}

func selectProxyNode(configDir: String, group: String, node: String) -> Bool {
    let (port, secret) = controllerEndpoint(configDir: configDir)
    guard let encoded = group.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return false }
    let url = URL(string: "http://127.0.0.1:\(port)/proxies/\(encoded)")!
    var req = URLRequest(url: url)
    req.httpMethod = "PATCH"
    req.timeoutInterval = 3
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if !secret.isEmpty {
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
    }
    req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": node])
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    URLSession.shared.dataTask(with: req) { _, resp, _ in
        defer { sem.signal() }
        ok = (resp as? HTTPURLResponse)?.statusCode == 204
    }.resume()
    _ = sem.wait(timeout: .now() + 4)
    return ok
}

struct ContentView: View {
    @State private var status = "unknown"
    @State private var busy = false
    @State private var selectedConfig = ""
    @State private var configs: [String] = []
    @State private var lastError = ""
    @State private var showLog = false
    @State private var proxyGroups: [ProxyGroupInfo] = []
    @State private var wasRunning = false

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("mihomo")
                .font(.system(size: 34, weight: .bold))

            if !selectedConfig.isEmpty {
                Text("当前配置: \(selectedConfig)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Circle()
                .fill(statusColor)
                .frame(width: 120, height: 120)
                .overlay(
                    Text(statusText)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                )

            Button(action: toggle) {
                Text(busy ? "..." : actionLabel)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 200, height: 56)
                    .background(actionColor)
                    .cornerRadius(14)
            }
            .disabled(busy)

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
                .onChange(of: selectedConfig) { newValue in
                    applyConfig(newValue)
                }

                if !lastError.isEmpty {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                if status == "running" {
                    VStack(spacing: 8) {
                        Text("节点切换")
                            .font(.headline)

                        ForEach(proxyGroups) { group in
                            HStack {
                                Text(group.name)
                                    .font(.footnote)
                                Spacer()
                                Menu {
                                    ForEach(group.all, id: \.self) { node in
                                        Button(node) {
                                            switchNode(group: group.name, node: node)
                                        }
                                    }
                                } label: {
                                    Text(group.now)
                                        .font(.footnote)
                                        .foregroundColor(.blue)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                        }

                        if proxyGroups.isEmpty {
                            Text("未获取到节点，mihomo 可能未运行或 API 端口不符")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                }

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
        }
        .sheet(isPresented: $showLog) {
            LogView()
        }
    }

    private var statusColor: Color {
        switch status {
        case "running": return .green
        case "stopped": return .gray
        default: return .orange
        }
    }

    private var statusText: String {
        switch status {
        case "running": return "运行中"
        case "stopped": return "已停止"
        default: return "未知"
        }
    }

    private var actionLabel: String {
        status == "running" ? "关闭" : "开启"
    }

    private var actionColor: Color {
        status == "running" ? .red : .blue
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

    private func toggle() {
        busy = true
        lastError = ""
        if status == "running" {
            stopMihomo()
            refreshStatus()
        } else {
            let pid = startMihomo(configPath: currentConfigPath())
            if pid > 0 {
                lastError = "mihomo 已启动 (pid \(pid))"
            } else {
                lastError = lastSpawnError.isEmpty ? "启动失败" : lastSpawnError
            }
            refreshStatus()
        }
        busy = false
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
        if running && !wasRunning {
            loadProxyGroupsInBackground()
        }
        if !running {
            proxyGroups = []
        }
        wasRunning = running
    }

    private func loadProxyGroupsInBackground() {
        DispatchQueue.global().async {
            var groups: [ProxyGroupInfo] = []
            for _ in 0..<5 {
                groups = fetchProxyGroups(configDir: CONFIG_DIR)
                if !groups.isEmpty { break }
                usleep(1_000_000)
            }
            DispatchQueue.main.async {
                if processAlive(readPid()) {
                    self.proxyGroups = groups
                }
            }
        }
    }

    private func switchNode(group: String, node: String) {
        if selectProxyNode(configDir: CONFIG_DIR, group: group, node: node) {
            loadProxyGroupsInBackground()
            lastError = "已切换 \(group) -> \(node)"
        } else {
            lastError = "节点切换失败（API 未响应）"
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
