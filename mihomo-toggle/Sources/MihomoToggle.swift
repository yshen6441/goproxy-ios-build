import SwiftUI
import Foundation

let CTL_PATH = "/var/mobile/.config/mihomo/.ctl"
let STATUS_PATH = "/var/mobile/.config/mihomo/.status"

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

    private let timer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 40) {
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

            Text("配置文件: /var/mobile/.config/mihomo/baidu.yaml")
                .font(.footnote)
                .foregroundColor(.secondary)

            Spacer()
        }
        .onReceive(timer) { _ in
            refreshStatus()
        }
        .onAppear {
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

    private func toggle() {
        busy = true
        let cmd = status == "running" ? "stop" : "start"
        try? Data(cmd.utf8).write(to: URL(fileURLWithPath: CTL_PATH))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            refreshStatus()
            busy = false
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
