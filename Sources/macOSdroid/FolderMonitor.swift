import Dispatch
import Foundation

/// Wraps the low-level file-system event source used to react to changes inside the watched APK
/// inbox without polling continuously.
final class FolderMonitor {
    private let url: URL
    private let queue = DispatchQueue(label: "macOSdroid.folder-monitor")
    private let onChange: @Sendable () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1

    init(url: URL, onChange: @escaping @Sendable () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    /// Starts watching the directory and replaces any previous watch handle.
    func start() throws {
        stop()

        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw CocoaError(.fileReadUnknown)
        }

        let descriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.attrib, .delete, .extend, .rename, .write],
            queue: queue
        )

        source.setEventHandler { [onChange] in
            onChange()
        }

        source.setCancelHandler {
            close(descriptor)
        }

        self.source = source
        source.resume()
    }

    /// Cancels the dispatch source and lets the cancel handler close the underlying descriptor.
    func stop() {
        source?.cancel()
        source = nil

        if descriptor >= 0 {
            descriptor = -1
        }
    }

    deinit {
        stop()
    }
}
