import Darwin
import Foundation
import PTYShim

/// M0-only errors. Production UI maps structured errors through String Catalog.
struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

/// One bounded probe transaction. It owns and always reaps its child process.
/// Blocking POSIX calls run on a dedicated Foundation Thread, never MainActor or
/// Swift's cooperative executor. Production transport needs cancellation-aware IO.
private final class PTYTransaction {
    private let descriptor: Int32
    private let processID: pid_t
    private var reaped = false

    init(launcher: String, executable: String, arguments: [String]) throws {
        let values = ([launcher, "--pty-exec", executable] + arguments).map { strdup($0) }
        let environment = [strdup("PATH=/usr/bin:/bin"), strdup("TERM=xterm-256color"),
                           strdup("LANG=en_US.UTF-8")]
        defer { for value in values + environment { free(value) } }
        var argv = values + [nil]
        var envp = environment + [nil]
        var fd: Int32 = -1
        var pid: pid_t = 0
        let error = launcher.withCString { path in
            ds_pty_spawn(path, &argv, &envp, 24, 80, &fd, &pid)
        }
        guard error == 0 else { throw ProbeFailure(description: "PTY 启动失败：\(String(cString: strerror(error)))") }
        descriptor = fd
        processID = pid
    }

    deinit {
        close(descriptor)
        if !reaped { ds_pty_abort(processID) }
    }

    func read(maximum: Int = 16_384) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: maximum)
        let count = bytes.withUnsafeMutableBytes { storage in
            ds_pty_read(descriptor, storage.baseAddress, storage.count, 5_000)
        }
        guard count >= 0 else { throw ProbeFailure(description: "PTY 读取失败：\(String(cString: strerror(errno)))") }
        return Array(bytes.prefix(count))
    }

    func readLine() throws -> String {
        var line: [UInt8] = []
        while line.count < 512 {
            let part = try read(maximum: 1)
            guard let value = part.first else { throw ProbeFailure(description: "PTY 在响应前关闭") }
            if value == 10 { return String(decoding: line, as: UTF8.self) }
            line.append(value)
        }
        throw ProbeFailure(description: "本地测试响应超过 512 字节")
    }

    func command(_ byte: UInt8) throws {
        let error = ds_pty_write_command(descriptor, byte)
        guard error == 0 else { throw ProbeFailure(description: "PTY 命令写入失败：\(error)") }
    }

    func resize(rows: UInt16, columns: UInt16) throws {
        let error = ds_pty_resize(descriptor, rows, columns)
        guard error == 0 else { throw ProbeFailure(description: "PTY 尺寸更新失败：\(error)") }
    }

    func wait() throws -> Int32 {
        var exitCode: Int32 = -1
        let error = ds_pty_wait(processID, &exitCode)
        guard error == 0 else { throw ProbeFailure(description: "子进程回收失败：\(error)") }
        reaped = true
        return exitCode
    }
}

/// Actor exposes only complete probe results. No pointers or file handles cross
/// its boundary; one dedicated worker performs each finite transaction.
actor ProbeRunner {
    func run(executable: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do { continuation.resume(returning: try Self.perform(executable: executable)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func perform(executable: String) throws -> [String] {
        let child = try PTYTransaction(launcher: executable, executable: executable, arguments: ["--pty-fixture"])
        let initial = try child.readLine()
        guard initial.hasPrefix("READY rows=24 cols=80 ctty=1 leader=1 devtty_errno=") else {
            throw ProbeFailure(description: "控制终端验证失败：\(initial)")
        }
        try child.resize(rows: 43, columns: 132)
        try child.command(115) // s: ask the fixture to inspect its own tty.
        let resized = try child.readLine()
        guard resized == "SIZE rows=43 cols=132 winch=1" else {
            throw ProbeFailure(description: "窗口更新或 SIGWINCH 验证失败：\(resized)")
        }
        try child.command(116) // t: generate exactly 2 MiB, including every byte value.
        // Deliberately pause the consumer: the child's finite kernel PTY buffer
        // fills and blocks its writer. This is not an in-memory output queue.
        Thread.sleep(forTimeInterval: 0.15)
        var total = 0
        let expected = 2 * 1_024 * 1_024
        while total < expected {
            let bytes = try child.read(maximum: min(16_384, expected - total))
            guard !bytes.isEmpty else { throw ProbeFailure(description: "大输出提前结束：\(total) 字节") }
            for (index, byte) in bytes.enumerated() {
                guard byte == UInt8(truncatingIfNeeded: total + index) else {
                    throw ProbeFailure(description: "原始字节校验失败，偏移 \(total + index)")
                }
            }
            total += bytes.count
        }
        try child.command(113) // q
        guard try child.wait() == 0 else { throw ProbeFailure(description: "本地测试子进程异常退出") }
        // Exercise the actual system ssh executable through the same PTY, offline.
        let ssh = try PTYTransaction(launcher: executable, executable: "/usr/bin/ssh", arguments: ["-V"])
        var version: [UInt8] = []
        while true {
            let bytes = try ssh.read()
            if bytes.isEmpty { break }
            guard version.count + bytes.count <= 4_096 else { throw ProbeFailure(description: "ssh 版本输出异常过长") }
            version += bytes
        }
        guard try ssh.wait() == 0 else { throw ProbeFailure(description: "系统 ssh 版本检查失败") }
        var results = ["PASS：独立 session、控制终端、初始尺寸 24×80",
                "诊断：\(initial)（devtty_errno 非零表示执行环境限制 /dev/tty 打开，不能认作完整交互认证验收）",
                "PASS：TIOCSWINSZ 更新为 43×132，子进程收到 SIGWINCH",
                "PASS：消费者暂停后，2,097,152 个原始字节完整且按序；单次读取最多 16 KiB",
                "PASS：系统 /usr/bin/ssh 经 PTY 启动，\(String(decoding: version, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))",
                "范围：未连接网络，未读取用户私钥，未验证服务器认证与远端 window-change。"]
        results += try verifyGeneratedKeyFormats(launcher: executable)
        return results
    }

    /// Generated fixture keys are unencrypted, disposable, and never printed.
    /// The empty -N/-P arguments contain no secret. Encrypted keys require the
    /// separate askpass design; this probe deliberately does not pass a secret.
    private static func verifyGeneratedKeyFormats(launcher: String) throws -> [String] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dockshell-key-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        var cleaned = false
        defer {
            if !cleaned {
                do { try FileManager.default.removeItem(at: directory) }
                catch { print("临时密钥文件清理失败：\(error)") }
            }
        }
        let fixtures: [(String, [String])] = [
            ("OpenSSH Ed25519", ["-t", "ed25519"]),
            ("传统 PEM RSA", ["-t", "rsa", "-b", "2048", "-m", "PEM"])
        ]
        var results: [String] = []
        for (index, fixture) in fixtures.enumerated() {
            let path = directory.appendingPathComponent("fixture-\(index)").path
            let generated = try runKeygen(launcher: launcher,
                                         arguments: ["-q"] + fixture.1 + ["-N", "", "-f", path])
            guard generated == 0 else { throw ProbeFailure(description: "临时 \(fixture.0) 密钥生成失败") }
            let parsed = try runKeygen(launcher: launcher, arguments: ["-y", "-P", "", "-f", path])
            guard parsed == 0 else { throw ProbeFailure(description: "临时 \(fixture.0) 私钥解析失败") }
            results.append("PASS：临时无口令 \(fixture.0) 私钥经系统 ssh-keygen 生成并解析")
        }
        try FileManager.default.removeItem(at: directory)
        cleaned = true
        results.append("PASS：临时密钥测试目录已清理")
        return results
    }

    private static func runKeygen(launcher: String, arguments: [String]) throws -> Int32 {
        let process = try PTYTransaction(launcher: launcher, executable: "/usr/bin/ssh-keygen", arguments: arguments)
        var outputCount = 0
        while true {
            let bytes = try process.read()
            if bytes.isEmpty { break }
            outputCount += bytes.count
            guard outputCount <= 4_096 else { throw ProbeFailure(description: "临时密钥验证输出异常过长") }
            // Discard output: successful -y emits only the generated public key.
        }
        return try process.wait()
    }
}

@main
struct SystemSSHProbe {
    static func main() async {
        if CommandLine.arguments.dropFirst().first == "--pty-exec", CommandLine.arguments.count >= 3 {
            let target = CommandLine.arguments[2]
            let values = Array(CommandLine.arguments.dropFirst(2)).map { strdup($0) }
            var argv = values + [nil]
            let error = target.withCString { ds_pty_exec($0, &argv) }
            for value in values { free(value) }
            print("PTY launcher 失败：\(error)")
            exit(126)
        }
        if CommandLine.arguments.dropFirst().first == "--pty-fixture" {
            exit(ds_pty_fixture())
        }
        guard CommandLine.arguments.count == 1 || CommandLine.arguments.dropFirst().first == "--self-test" else {
            print("用法：system-ssh-probe [--self-test]")
            exit(2)
        }
        do {
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            for line in try await ProbeRunner().run(executable: executable) { print(line) }
        } catch {
            print("FAIL：\(error)")
            exit(1)
        }
    }
}
