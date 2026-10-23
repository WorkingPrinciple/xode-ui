import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@main
struct CaptureWindow {
    @MainActor
    static func main() async {
        do {
            let args = CommandLine.arguments
            guard args.count == 5, let pid = pid_t(args[1]), pid > 0,
                  let windowID = CGWindowID(args[2]), !args[3].isEmpty else {
                throw CaptureError.invalidArguments
            }
            _ = NSApplication.shared
            guard CGPreflightScreenCaptureAccess() else {
                throw CaptureError.permissionRequired
            }
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            let matches = content.windows.filter {
                $0.windowID == windowID && $0.owningApplication?.processID == pid
                    && $0.title == args[3] && $0.isOnScreen
            }
            guard matches.count == 1, let window = matches.first else {
                throw CaptureError.identityMismatch
            }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width)
            configuration.height = Int(window.frame.height)
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration
            )
            let url = URL(fileURLWithPath: args[4])
            guard !FileManager.default.fileExists(atPath: url.path),
                  let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil
                  ) else {
                throw CaptureError.outputRefused
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else {
                throw CaptureError.encodingFailed
            }
            print("{\"pid\":\(pid),\"window\":\(windowID),\"width\":\(image.width),\"height\":\(image.height),\"completed\":true}")
        } catch {
            FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
            exit(1)
        }
    }

    enum CaptureError: Error {
        case invalidArguments, permissionRequired, identityMismatch, outputRefused, encodingFailed
    }
}
