import Foundation

/// Watches a single file and reports changes.
///
/// Editors rarely write in place: most do an "atomic save" — write a temp file,
/// then rename it over the original. That deletes the inode we are watching, so
/// the watch has to be torn down and re-armed against the new one rather than
/// simply firing.
final class FileWatcher {
    enum Event {
        case changed
        case vanished
    }

    private let url: URL
    private let debounce: TimeInterval
    private let handler: (Event) -> Void

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "pt.miguelsilva.imark.watch")

    init(url: URL, debounce: TimeInterval = 0.12, handler: @escaping (Event) -> Void) {
        self.url = url
        self.debounce = debounce
        self.handler = handler
        arm()
    }

    deinit { disarm() }

    private func arm() {
        disarm()

        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // File is gone for the moment — an atomic save has a window where
            // neither the old nor the new file is in place. Look again shortly.
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                if FileManager.default.fileExists(atPath: self.url.path) {
                    self.arm()
                    self.notify(.changed)
                } else {
                    self.notify(.vanished)
                }
            }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue
        )

        source.setEventHandler { [weak self] in
            guard let self, let source = self.source else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) || flags.contains(.revoke) {
                self.arm()          // re-attach to whatever now lives at the path
                self.notify(.changed)
            } else {
                self.notify(.changed)
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }

        self.source = source
        source.resume()
    }

    private func disarm() {
        source?.cancel()
        source = nil
    }

    /// Editors can produce a burst of writes for a single save; collapse them.
    private func notify(_ event: Event) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let exists = FileManager.default.fileExists(atPath: self.url.path)
            DispatchQueue.main.async {
                self.handler(exists ? .changed : .vanished)
            }
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
