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
                // 已连设备列表 + 逐个「断开」（踢除）。
                if !server.clientList.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(server.clientList) { c in
                            HStack(spacing: 6) {
                                Image(systemName: "ipad").foregroundStyle(.secondary)
                                Text(c.address)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button(L("Disconnect")) { server.kick(c.id) }
                                    .buttonStyle(.borderless)
                                    .font(.caption)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                HStack {
                    Text(String(format: L("Inbound: %d msg/s"), server.inboundRate))
                        .foregroundStyle(.secondary)
                    Spacer()
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
