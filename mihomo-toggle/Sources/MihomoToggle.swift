import SwiftUI
import Foundation

let CONFIG_DIR = "/var/mobile/.config/mihomo"
let CTL_PATH = CONFIG_DIR + "/.ctl"
let STATUS_PATH = CONFIG_DIR + "/.status"
let CFG_PATH = CONFIG_DIR + "/.config_path"

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

                Text("配置文件目录: \(CONFIG_DIR)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
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
    }

    private var statusColor: Color {
        switch status {
        case "running": return .green
        case "stopped": return .gray
        case "error": return .red
        default: return .orange
        }
    }

    private var statusText: String {
        switch status {
        case "running": return "运行中"
        case "stopped": return "已停止"
        case "error": return "启动失败"
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

    private func applyConfig(_ name: String) {
        guard !name.isEmpty else { return }
        let fullPath = CONFIG_DIR + "/" + name
        do {
            try Data(fullPath.utf8).write(to: URL(fileURLWithPath: CFG_PATH))
            lastError = "已切换到 \(name)，正在重启 mihomo..."
        } catch {
            lastError = "写入配置失败: \(error.localizedDescription)"
            return
        }
        sendCmd("restart")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            refreshStatus()
        }
    }

    private func toggle() {
        busy = true
        lastError = ""
        let cmd = status == "running" ? "stop" : "start"
        sendCmd(cmd)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            refreshStatus()
            busy = false
        }
    }

    private func sendCmd(_ cmd: String) {
        do {
            try Data(cmd.utf8).write(to: URL(fileURLWithPath: CTL_PATH))
        } catch {
            lastError = "写入控制文件失败: \(error.localizedDescription)"
        }
    }

    private func refreshStatus() {
        if let s = try? String(contentsOfFile: STATUS_PATH, encoding: .utf8) {
            let v = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if v == "running" || v == "stopped" || v == "error" {
                status = v
            }
        }
    }
}
