import Foundation
import WatchConnectivity

/// Sends a diagnostic bundle to the iPhone app with WatchConnectivity. The system
/// finishes the transfer in the background, even after this app is suspended;
/// the iPhone app stores the file and offers it for sharing.
@MainActor final class LogTransfer: NSObject, WCSessionDelegate {
    private(set) var status = "Logs stay on this Watch until you send them."
    var changed: (() -> Void)?
    private let outbox: URL

    override init() {
        outbox = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("log-outbox", isDirectory: true)
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ text: String, name: String) {
        guard WCSession.isSupported() else { return report("This Watch can't send files to an iPhone.") }
        let session = WCSession.default
        guard session.activationState == .activated else {
            session.activate()
            return report("Connecting to the iPhone. Try again in a moment.")
        }
        guard session.isCompanionAppInstalled else {
            return report("Install X6 Remote on the iPhone first.")
        }
        do {
            try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
            let file = outbox.appendingPathComponent(name)
            try Data(text.utf8).write(to: file, options: .atomic)
            session.transferFile(file, metadata: ["kind": "x6-logs"])
            report("Sending \(name). Open X6 Remote on the iPhone to receive it.")
        } catch {
            report("Couldn't prepare the log file: \(error.localizedDescription)")
        }
    }

    private func report(_ message: String) {
        status = message
        changed?()
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {}

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let file = fileTransfer.file.fileURL
        let failure = error?.localizedDescription
        Task { @MainActor in
            if let failure {
                self.report("Sending failed: \(failure). Try again with the iPhone nearby.")
            } else {
                try? FileManager.default.removeItem(at: file)
                let time = Date().formatted(date: .omitted, time: .shortened)
                self.report("Sent \(file.lastPathComponent) to the iPhone at \(time).")
            }
        }
    }
}
