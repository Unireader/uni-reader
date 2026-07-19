import SwiftUI

/// 平板手写服务控制面板：启停、二维码配对、连接数、最近消息。
struct ServerPanel: View {
    @ObservedObject var server: LANServer

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(L("Tablet Handwriting")).font(.headline)
                Spacer()
                Button(server.isRunning ? L("Stop") : L("Start")) {
                    if server.isRunning { server.stop() } else { server.start() }
                }
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(server.isRunning ? Color.green : Color.secondary)
                    .frame(width: 10, height: 10)
                Text(server.isRunning ? L("Server running") : L("Server stopped"))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if server.isRunning {
                if let qr = Pairing.qrImage(from: server.pageURL) {
                    Image(nsImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 180, height: 180)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Text(L("Open this URL in Firefox on your tablet:"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(server.pageURL)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                Divider()
                HStack {
                    Text(String(format: L("Connected tablets: %d"), server.clientCount))
                    Spacer()
                    if let ms = server.latencyMS {
                        Text(String(format: L("Latency: %d ms"), ms)).foregroundStyle(.secondary)
                    }
                }
                .font(.footnote)
                if !server.lastInbound.isEmpty {
                    Text(L("Last message:")).font(.caption).foregroundStyle(.secondary)
                    Text(server.lastInbound)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(18)
        .frame(width: 300)
    }
}
