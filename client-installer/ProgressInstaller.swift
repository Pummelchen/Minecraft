import AppKit
import Foundation

final class InstallerApp: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let titleLabel = NSTextField(labelWithString: "Pummelchen Client Installer")
    private let stepLabel = NSTextField(labelWithString: "Preparing...")
    private let detailLabel = NSTextField(labelWithString: "Starting installer")
    private let progressBar = NSProgressIndicator()
    private let logView = NSTextView()
    private let openLogButton = NSButton(title: "Open Log", target: nil, action: nil)
    private let closeButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var task: Process?
    private var outputBuffer = ""
    private var logPath: String?
    private var finished = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        NSApp.activate(ignoringOtherApps: true)
        startInstaller()
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pummelchen Installer"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSView()
        window.makeKeyAndOrderFront(nil)

        guard let content = window.contentView else { return }
        titleLabel.font = .boldSystemFont(ofSize: 22)
        stepLabel.font = .boldSystemFont(ofSize: 14)
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 3

        progressBar.minValue = 0
        progressBar.maxValue = 10
        progressBar.doubleValue = 0
        progressBar.isIndeterminate = false

        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .labelColor
        logView.backgroundColor = .textBackgroundColor

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.documentView = logView
        scrollView.borderType = .bezelBorder

        openLogButton.target = self
        openLogButton.action = #selector(openLog)
        openLogButton.isEnabled = false
        closeButton.target = self
        closeButton.action = #selector(cancelOrClose)

        let buttonRow = NSStackView(views: [openLogButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.distribution = .gravityAreas
        buttonRow.spacing = 10

        let stack = NSStackView(views: [titleLabel, stepLabel, detailLabel, progressBar, scrollView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            stepLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progressBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 250),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func startInstaller() {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("install-bootstrap.sh").path else {
            fail("Installer resource is missing.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script]
        var environment = ProcessInfo.processInfo.environment
        environment["PUMMELCHEN_SKIP_DIALOGS"] = "1"
        environment["PUMMELCHEN_UI"] = "1"
        environment["PUMMELCHEN_NONINTERACTIVE"] = "1"
        environment["PUMMELCHEN_OPEN_LAUNCHER"] = environment["PUMMELCHEN_OPEN_LAUNCHER"] ?? "1"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.consume(text)
            }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.taskFinished(status: process.terminationStatus)
            }
        }

        do {
            try process.run()
            task = process
        } catch {
            fail("Could not start installer: \(error.localizedDescription)")
        }
    }

    private func consume(_ text: String) {
        outputBuffer += text
        let lines = outputBuffer.components(separatedBy: .newlines)
        outputBuffer = lines.last ?? ""
        for line in lines.dropLast() {
            processLine(line)
        }
    }

    private func processLine(_ line: String) {
        if line.hasPrefix("PUMMELCHEN_PROGRESS\t") {
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 4, let current = Double(parts[1]), let total = Double(parts[2]) {
                progressBar.maxValue = total
                progressBar.doubleValue = current
                stepLabel.stringValue = "Step \(Int(current)) of \(Int(total))"
                detailLabel.stringValue = parts.dropFirst(3).joined(separator: "\t")
            }
            return
        }
        if line.hasPrefix("PUMMELCHEN_DETAIL\t") {
            detailLabel.stringValue = String(line.dropFirst("PUMMELCHEN_DETAIL\t".count))
            return
        }
        if line.hasPrefix("PUMMELCHEN_LOG\t") {
            logPath = String(line.dropFirst("PUMMELCHEN_LOG\t".count))
            openLogButton.isEnabled = true
            return
        }
        if line.hasPrefix("PUMMELCHEN_FAIL\t") {
            fail(String(line.dropFirst("PUMMELCHEN_FAIL\t".count)))
            return
        }
        if line.hasPrefix("PUMMELCHEN_DONE\t") {
            detailLabel.stringValue = String(line.dropFirst("PUMMELCHEN_DONE\t".count))
            progressBar.doubleValue = progressBar.maxValue
            return
        }
        appendLog(line)
    }

    private func appendLog(_ line: String) {
        let text = NSAttributedString(string: line + "\n")
        logView.textStorage?.append(text)
        logView.scrollRangeToVisible(NSRange(location: logView.string.count, length: 0))
    }

    private func taskFinished(status: Int32) {
        if finished { return }
        finished = true
        task = nil
        if status == 0 {
            progressBar.doubleValue = progressBar.maxValue
            stepLabel.stringValue = "Ready to play"
            detailLabel.stringValue = "Ready to play Pummelchen Server. Minecraft Launcher is opening."
            closeButton.title = "Done"
        } else {
            stepLabel.stringValue = "Install failed"
            if !detailLabel.stringValue.hasPrefix("PUMMELCHEN") {
                detailLabel.stringValue = "The installer stopped with exit code \(status). Open the log for details."
            }
            closeButton.title = "Close"
        }
    }

    private func fail(_ message: String) {
        stepLabel.stringValue = "Install failed"
        detailLabel.stringValue = message
        closeButton.title = "Close"
        finished = true
    }

    @objc private func openLog() {
        guard let logPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc private func cancelOrClose() {
        if let task, task.isRunning {
            task.terminate()
            return
        }
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = InstallerApp()
app.delegate = delegate
app.run()
