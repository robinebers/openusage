import Foundation
import OpenUsageCore
import Win32Shim

typealias PipeHandle = UnsafeMutableRawPointer

enum NamedPipeTransport {
    static func pipeName() -> String {
        let user = ProcessInfo.processInfo.userName
        return "\\\\.\\pipe\\OpenUsageCore-\(user)"
    }

    static func pipeNameWide() -> [UInt16] {
        pipeName().utf16 + [0]
    }

    static func createServer() throws -> PipeHandle {
        var handle: ou_pipe_handle?
        let ok = pipeNameWide().withUnsafeBufferPointer { buffer in
            ou_pipe_create_user_restricted(buffer.baseAddress, &handle)
        }
        guard ok != 0, let handle else {
            throw SidecarPipeError.createFailed
        }
        return handle
    }

    static func waitForClient(_ pipe: PipeHandle) throws {
        guard ou_pipe_wait_client(pipe) != 0 else {
            throw SidecarPipeError.acceptFailed
        }
    }

    static func readLine(_ pipe: PipeHandle) -> String? {
        var out: UnsafeMutablePointer<CChar>?
        var len: size_t = 0
        guard ou_pipe_read_line(pipe, &out, &len) != 0 else {
            return nil
        }
        defer { if let out { ou_pipe_free_string(out) } }
        guard let out else { return nil }
        return String(cString: out)
    }

    static func writeLine(_ pipe: PipeHandle, _ line: String) throws {
        let ok = line.withCString { ou_pipe_write_line(pipe, $0) }
        guard ok != 0 else {
            throw SidecarPipeError.writeFailed
        }
    }

    static func disconnect(_ pipe: PipeHandle) {
        ou_pipe_disconnect(pipe)
    }

    static func close(_ pipe: PipeHandle) {
        ou_pipe_close(pipe)
    }
}

enum SidecarPipeError: Error {
    case createFailed
    case acceptFailed
    case writeFailed
}

@MainActor
enum SidecarServer {
    static func run() async {
        let service = SidecarService()
        await service.bootstrap()

        let wideName = NamedPipeTransport.pipeName()
        AppLog.info(.lifecycle, "sidecar pipe listening name=\(wideName) version=\(SidecarProtocol.version)")
        print("OpenUsage sidecar starting pipe=\(wideName) version=\(SidecarProtocol.version)")

        // Sequential accept/handle: blocking ReadFile must not share @MainActor with a
        // concurrent accept loop (that starved session handlers after the Widgets spike).
        while true {
            let pipe: PipeHandle
            do {
                pipe = try NamedPipeTransport.createServer()
            } catch {
                print("sidecar pipe create failed: \(error)")
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            do {
                try NamedPipeTransport.waitForClient(pipe)
            } catch {
                NamedPipeTransport.close(pipe)
                continue
            }

            await handleSession(pipe: pipe, service: service)
            NamedPipeTransport.disconnect(pipe)
            NamedPipeTransport.close(pipe)
        }
    }

    private static func handleSession(pipe: PipeHandle, service: SidecarService) async {
        while let line = NamedPipeTransport.readLine(pipe), !line.isEmpty {
            do {
                let request = try SidecarIPCCodec.decodeRequestLine(line)
                let response = try await service.handle(request)
                let out = try SidecarIPCCodec.encodeLine(response)
                try NamedPipeTransport.writeLine(pipe, out)
            } catch let SidecarIPCError.unknownOperation(op) {
                let response = SidecarResponse.error("Unknown operation: \(op)")
                if let out = try? SidecarIPCCodec.encodeLine(response) {
                    try? NamedPipeTransport.writeLine(pipe, out)
                }
            } catch {
                let response = SidecarResponse.error(error.localizedDescription)
                if let out = try? SidecarIPCCodec.encodeLine(response) {
                    try? NamedPipeTransport.writeLine(pipe, out)
                }
            }
        }
    }
}

@MainActor
@main
enum SidecarEntry {
    static func main() async {
        AppLog.bootstrap()
        AppLog.info(.lifecycle, "OpenUsage sidecar starting")
        await SidecarServer.run()
    }
}
