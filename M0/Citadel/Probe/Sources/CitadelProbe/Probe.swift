import Foundation
import Darwin
@preconcurrency import Citadel

/// An isolated M0 compatibility probe. Its default mode performs no network or credential I/O.
@main
enum CitadelProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        // File reads and terminal prompts must not execute on MainActor.
        let status = await Task.detached {
            do {
                try await run(arguments)
                return Int32(0)
            } catch let error as ProbeError {
                FileHandle.standardError.write(Data((error.message + "\n").utf8))
                return Int32(1)
            } catch {
                // Do not print library errors: they may contain connection or authentication data.
                FileHandle.standardError.write(Data("验证失败：请检查网络、主机公钥、认证方式与私钥格式；本探针不输出底层错误内容。\n".utf8))
                return Int32(1)
            }
        }.value
        exit(status)
    }

    nonisolated static func run(_ arguments: [String]) async throws {
        guard arguments.first == "connect" else {
            let method = SSHAuthenticationMethod.passwordBased(username: "m0-unused", password: "m0-placeholder-not-a-secret")
            let validator = SSHHostKeyValidator.trustedKeys([])
            print("离线已构造：\(type(of: method))、\(type(of: validator))；未发起网络连接。")
            print("""
            Citadel 0.12.1 / Swift 6 M0 探针
            默认 inspect：不联网、不读取用户私钥、不访问 ssh-agent。
            原版 macOS 14：密码/命令执行 API 可用；交互 PTY API 要求 macOS 15。
            agent：原版没有现成适配器；本探针明确拒绝，未 fork、未打补丁。

            可选实机验证（仅由你主动运行）：
              citadel-probe connect --host HOST --user USER --host-key-file PUBLIC_KEY --auth password [--pty]
              citadel-probe connect --host HOST --user USER --host-key-file PUBLIC_KEY --auth ed25519 --key-file KEY [--pty]
              citadel-probe connect --host HOST --user USER --host-key-file PUBLIC_KEY --auth rsa --key-file KEY --legacy [--pty]
            --port 默认为 22。PUBLIC_KEY 是经独立可信渠道确认的“算法 base64”公钥文件，不能直接传入 known_hosts。
            口令只从当前终端隐藏读取，不从参数或环境变量读取，不写入文件或日志。
            --legacy 显式启用 Citadel 内置兼容算法；仅用于隔离测试，不是产品默认策略。
            非 PTY 模式只执行固定 printf；PTY 模式请求 80x24，改为 120x40，再执行 stty size 并退出。
            """)
            return
        }

        let options = try Options(Array(arguments.dropFirst()))
        guard options.auth != "agent" else {
            throw ProbeError("原版 Citadel 没有可直接使用的 ssh-agent 适配器；本轮没有修改依赖，无法执行此验证。")
        }
        guard ["password", "ed25519", "rsa"].contains(options.auth) else {
            throw ProbeError("认证方式仅支持 password、ed25519、rsa；agent 本轮仅评估。")
        }
        if options.pty {
            guard #available(macOS 15, *) else {
                throw ProbeError("Citadel 0.12.1 的公开交互 PTY API 要求 macOS 15；macOS 14 验证在此明确停止。")
            }
        }
        if options.auth == "rsa", !options.legacy {
            throw ProbeError("Citadel 的此 RSA 路径使用 ssh-rsa / SHA-1。仅隔离测试可显式添加 --legacy；尚未证明 RSA-SHA2 兼容。")
        }

        let hostPublicKey = try String(contentsOfFile: options.hostKeyFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostPublicKey.contains("\n"), !hostPublicKey.hasPrefix("#") else {
            throw ProbeError("主机公钥文件必须只含一条 OpenSSH 公钥，格式为“算法 base64”，不能传入 known_hosts 文件。")
        }
        guard !hostPublicKey.hasPrefix("ssh-rsa ") else {
            throw ProbeError("此最小探针的主机公钥固定校验尚未接入 Citadel 自定义 RSA 注册；请使用该主机已确认的 Ed25519/ECDSA 公钥。RSA 主机密钥兼容仍待独立验证。")
        }
        let validator: SSHHostKeyValidator = .trustedKeys([try .init(openSSHPublicKey: hostPublicKey)])
        let authentication: SSHAuthenticationMethod
        switch options.auth {
        case "password":
            authentication = .passwordBased(username: options.user, password: try readSecret("登录密码："))
        case "ed25519", "rsa":
            guard let keyFile = options.keyFile else {
                throw ProbeError("私钥认证需要 --key-file；本探针不会搜索默认私钥目录。")
            }
            let key = try String(contentsOfFile: keyFile, encoding: .utf8)
            guard key.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----") else {
                throw ProbeError("本 Citadel 探针只接受 OpenSSH 私钥容器；老式 PEM 和 PuTTY .ppk 未接入，需先另存为支持的 OpenSSH 格式。")
            }
            let passphrase = try readSecret("私钥口令（无口令直接回车）：")
            let decryptionKey = passphrase.isEmpty ? nil : Data(passphrase.utf8)
            if options.auth == "ed25519" {
                authentication = .ed25519(username: options.user, privateKey: try .init(sshEd25519: key, decryptionKey: decryptionKey))
            } else {
                authentication = .rsa(username: options.user, privateKey: try .init(sshRsa: key, decryptionKey: decryptionKey))
            }
        default:
            throw ProbeError("不支持此认证方式。")
        }

        let client = try await SSHClient.connect(
            host: options.host,
            port: options.port,
            authenticationMethod: authentication,
            hostKeyValidator: validator,
            reconnect: .never,
            algorithms: options.legacy ? .all : .init()
        )
        do {
            if options.pty {
                if #available(macOS 15, *) {
                    try await probePTY(client)
                }
            } else {
                let output = try await client.executeCommand("printf 'DockShell Citadel M0: 中文 😀\\n'", maxResponseSize: 65536)
                FileHandle.standardOutput.write(Data(output.readableBytesView))
            }
            try await client.close()
        } catch {
            try? await client.close()
            throw error
        }
    }

    @available(macOS 15, *)
    nonisolated static func probePTY(_ client: SSHClient) async throws {
        try await client.withPTY(.init(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: 80,
            terminalRowHeight: 24,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: .init([:])
        )) { inbound, outbound in
            try await outbound.changeSize(cols: 120, rows: 40, pixelWidth: 0, pixelHeight: 0)
            try await outbound.write(.init(string: "stty size; printf 'DockShell PTY M0: 中文 😀\\n'; exit\n"))
            for try await output in inbound {
                switch output {
                case .stdout(let bytes), .stderr(let bytes):
                    FileHandle.standardOutput.write(Data(bytes.readableBytesView))
                }
            }
        }
    }

    /// getpass opens the controlling terminal and disables echo. The returned C buffer is erased.
    nonisolated static func readSecret(_ prompt: String) throws -> String {
        guard isatty(STDIN_FILENO) == 1 else {
            throw ProbeError("读取口令需要交互式终端；拒绝从管道或环境变量读取凭据。")
        }
        guard let value = getpass(prompt) else {
            throw ProbeError("无法从终端读取口令。")
        }
        defer {
            let length = strlen(value)
            _ = memset_s(value, length, 0, length)
        }
        return String(cString: value)
    }
}

private struct ProbeError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

private struct Options {
    let host: String
    let user: String
    let hostKeyFile: String
    let auth: String
    let keyFile: String?
    let port: Int
    let pty: Bool
    let legacy: Bool

    init(_ arguments: [String]) throws {
        var values: [String: String] = [:]
        var flags = Set<String>()
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            if ["--pty", "--legacy"].contains(key) {
                flags.insert(key)
                index += 1
                continue
            }
            guard ["--host", "--user", "--host-key-file", "--auth", "--key-file", "--port"].contains(key),
                  index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                throw ProbeError("参数无效；请运行 citadel-probe inspect 查看用法。")
            }
            values[key] = arguments[index + 1]
            index += 2
        }
        guard let host = values["--host"], !host.isEmpty,
              let user = values["--user"], !user.isEmpty,
              let hostKeyFile = values["--host-key-file"], !hostKeyFile.isEmpty,
              let auth = values["--auth"],
              let port = Int(values["--port"] ?? "22"), (1...65535).contains(port) else {
            throw ProbeError("缺少必填参数或端口无效；请运行 citadel-probe inspect 查看用法。")
        }
        self.host = host
        self.user = user
        self.hostKeyFile = hostKeyFile
        self.auth = auth
        self.keyFile = values["--key-file"]
        self.port = port
        self.pty = flags.contains("--pty")
        self.legacy = flags.contains("--legacy")
    }
}
