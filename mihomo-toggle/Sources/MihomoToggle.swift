import SwiftUI
import Darwin

let CONFIG_DIR = "/var/mobile/.config/mihomo"
let MIHOMO_BIN = "/var/jb/usr/local/bin/mihomo"
let PID_PATH = CONFIG_DIR + "/.mihomo.pid"
let CFG_PATH = CONFIG_DIR + "/.config_path"
let LOG_PATH = CONFIG_DIR + "/mihomo.log"

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

@discardableResult
func startMihomo(configPath: String) -> pid_t {
    stopMihomo()
    usleep(200_000)

    let argv: [UnsafeMutablePointer<CChar>?] = [
        strdup(MIHOMO_BIN),
        strdup("-d"),
        strdup(CONFIG_DIR),
        strdup("-f"),
        strdup(configPath),
        nil
    ]
    defer {
        for p in argv { if let p = p { free(p) } }
    }

    let logFD = open(LOG_PATH, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    let fileActions = UnsafeMutablePointer<posix_spawn_file_actions_t>.allocate(capacity: 1)
    posix_spawn_file_actions_init(fileActions)
    defer {
        posix_spawn_file_actions_destroy(fileActions)
        fileActions.deallocate()
    }
    if logFD >= 0 {
        posix_spawn_file_actions_adddup2(fileActions, logFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(fileActions, logFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(fileActions, logFD)
    }

    let attr = UnsafeMutablePointer<posix_spawnattr_t>.allocate(capacity: 1)
    posix_spawnattr_init(attr)
    defer {
        posix_spawnattr_destroy(attr)
        attr.deallocate()
    }
    posix_spawnattr_setflags(attr, Int16(POSIX_SPAWN_SETPGROUP))

    var pid: pid_t = 0
    let rc = posix_spawn(&pid, MIHOMO_BIN, fileActions, attr, argv, nil)
    if rc == 0 && pid > 0 {
        try? Data("\(pid)".utf8).write(to: URL(fileURLWithPath: PID_PATH))
    }
    return pid
}

@main
struct MihomoToggleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
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

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Text("mihomo")
                .font(.system(size: 34, weight: .bold))

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
                lastError = "启动失败"
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
            lastError = "重启失败"
        }
        refreshStatus()
        busy = false
    }

    private func refreshStatus() {
        status = processAlive(readPid()) ? "running" : "stopped"
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
