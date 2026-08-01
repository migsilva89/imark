// Never runs. App extensions are entered through NSExtensionMain, which the
// linker flag in Package.swift installs as the entry point; SwiftPM just
// insists an executable target has a main file.
import Foundation

_ = PreviewViewController.self
