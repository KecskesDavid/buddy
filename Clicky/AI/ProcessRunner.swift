import Foundation

nonisolated struct ProcessOutput: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
}

/// Runs a process synchronously (call it off the main thread).
/// stdin is written and stdout/stderr are read concurrently, so large payloads can't deadlock on pipe buffers.
nonisolated enum ProcessRunner {
    nonisolated private final class Box: @unchecked Sendable {
        var data = Data()
        var timedOut = false
    }

    static func run(
        _ executable: URL,
        _ arguments: [String],
        stdin: Data? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }

        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()

        let group = DispatchGroup()
        let errBox = Box()
        let flags = Box()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            if let stdin { try? inPipe.fileHandleForWriting.write(contentsOf: stdin) }
            try? inPipe.fileHandleForWriting.close()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let killer = DispatchWorkItem {
            if process.isRunning {
                flags.timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        killer.cancel()

        return ProcessOutput(
            status: process.terminationStatus,
            stdout: outData,
            stderr: errBox.data,
            timedOut: flags.timedOut
        )
    }
}
