import SwiftUI

/// 设置 ›「服务器」：连过的服务器、连接新服务器、自动下载的 PDF 大小上限（方案 `SERVER-MODE-PLAN.md §2`）。
///
/// 输入框一律绑本页自己的 `@State`（`docs/agents/PITFALLS.md`：设置页绑静态属性的 Binding = 点了没反应）。
struct ServerSettingsView: View {
    @ObservedObject private var accounts = ServerAccounts.shared
    /// 局域网发现：本页显示时浏览，离开就停（`ServerDiscovery`）。
    @StateObject private var discovery = ServerDiscovery()
    @State private var address = ""
    @State private var code = ""
    @State private var deviceName = Host.current().localizedName ?? ""
    @State private var connecting = false
    @State private var errorText: String?
    /// 键与读取方 `ServerSyncCoordinator.largePDFBytes` 必须同一把，默认值也一致（50）。
    @AppStorage("serverLargePDFMB") private var largePDFMB = 50

    var body: some View {
        Form {
            Section {
                if accounts.all.isEmpty {
                    Text(L("No server connected yet."))
                }
                ForEach(accounts.all) { a in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.serverName.map { "\($0) · \(a.url)" } ?? a.url)
                            Text(String(format: L("This Mac appears as “%@”"), a.deviceName)).font(.callout)
                        }
                        Spacer()
                        Button(L("Disconnect")) { accounts.remove(a.id) }
                    }
                }
            } header: {
                Text(L("Connected Servers"))
            } footer: {
                Text(L("Disconnecting only forgets the sign-in on this Mac. Local copies of server workspaces stay, and sync again once you reconnect."))
            }

            Section {
                if discovery.found.isEmpty {
                    Text(L("Looking for servers on this network…"))
                }
                ForEach(discovery.found) { f in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name)
                            Text(nearbyDetail(f)).font(.callout)
                        }
                        Spacer()
                        nearbyAction(f)
                    }
                }
            } header: {
                Text(L("Servers Nearby"))
            } footer: {
                Text(L("Servers on the same network show up here when they listen on all interfaces (started with “--host 0.0.0.0”)."))
            }

            Section {
                TextField(L("Address"), text: $address, prompt: Text(verbatim: "192.168.1.5:8790"))
                TextField(L("Pairing Code"), text: $code)
                TextField(L("This Mac’s Name"), text: $deviceName)
                HStack {
                    if let errorText {
                        Text(errorText).foregroundStyle(.red)
                    }
                    Spacer()
                    if connecting { ProgressView().controlSize(.small) }
                    Button(L("Connect")) { connect() }
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || code.isEmpty || connecting)
                }
            } header: {
                Text(L("Connect to a Server"))
            } footer: {
                Text(L("Run “unireader-server pairing-code” on the server to see its pairing code."))
            }

            Section {
                Stepper(value: $largePDFMB, in: 5...2000, step: 5) {
                    Text(String(format: L("Download PDFs up to %d MB automatically"), largePDFMB))
                }
            } header: {
                Text(L("Downloads"))
            } footer: {
                Text(L("Larger PDFs are downloaded when you open them."))
            }
        }
        .formStyle(.grouped)
        .onAppear {
            discovery.start()
            Task { await accounts.fillMissingIdentities() }
        }
        .onDisappear { discovery.stop() }
    }

    /// 附近的这台已经连过了吗（按服务器身份认，不按地址——地址会变）。
    private func known(_ f: ServerDiscovery.Found) -> ServerAccount? {
        f.serverId.flatMap { accounts.account(forServerId: $0) }
    }

    private func nearbyDetail(_ f: ServerDiscovery.Found) -> String {
        let addr = f.address.map { $0.replacingOccurrences(of: "http://", with: "") } ?? L("Finding its address…")
        if let s = f.schema, s != LibraryStore.schemaVersion {
            return addr + " · " + String(format: L("data version %d (this app: %d)"), s, LibraryStore.schemaVersion)
        }
        return addr
    }

    /// 已连过且地址没变 → 「已连接」；已连过但地址变了 → 「更新地址」（要用户点，不自动改：别把令牌发给冒名的机器）；
    /// 没连过 → 「填入」（把地址填进下面的输入框，配对码还得用户自己输）。
    @ViewBuilder
    private func nearbyAction(_ f: ServerDiscovery.Found) -> some View {
        if let a = known(f) {
            // 记的是本机地址（127.0.0.1 / localhost）时两个地址都能用，不提示改
            if let addr = f.address, ServerClient.normalize(addr)?.absoluteString != a.url,
               !["127.0.0.1", "localhost", "::1"].contains(URL(string: a.url)?.host ?? "") {
                Button(L("Update Address")) { accounts.updateURL(a.id, to: addr) }
            } else {
                Text(L("Connected"))
            }
        } else if let addr = f.address {
            Button(L("Fill In")) { address = addr.replacingOccurrences(of: "http://", with: "") }
        }
    }

    private func connect() {
        connecting = true
        errorText = nil
        let name = deviceName.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                _ = try await accounts.add(address: address, code: code, deviceName: name.isEmpty ? L("Mac") : name)
                address = ""
                code = ""
            } catch {
                errorText = error.localizedDescription
            }
            connecting = false
        }
    }
}
