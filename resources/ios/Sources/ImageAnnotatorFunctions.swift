import Foundation
import UIKit

/// Image annotation editor. Namespace: "ImageAnnotator.*"
enum ImageAnnotatorFunctions {

    /// Presents the editor over a local image and returns straight away.
    /// The result arrives later as exactly one Saved, Cancelled or Failed event.
    /// Parameters:
    ///   - imagePath: string - local JPEG or PNG (required)
    ///   - originalPath: string - local original; enables Revert (optional)
    ///   - id: string - echoed back in every event (required)
    class Open: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            let id = Self.string(parameters["id"]) ?? ""
            let imagePath = Self.string(parameters["imagePath"])
            let originalPath = Self.string(parameters["originalPath"])

            guard let imagePath, FileManager.default.fileExists(atPath: imagePath) else {
                Pteal79Annotator.Session.reject(id: id, message: "Couldn't load the image.")
                return BridgeResponse.success(data: ["opened": false])
            }

            let request = Pteal79Annotator.Session.Request(id: id, imagePath: imagePath, originalPath: originalPath)
            guard Pteal79Annotator.Session.begin(request) else {
                Pteal79Annotator.Session.reject(id: id, message: Pteal79Annotator.Session.messageAlreadyOpen)
                return BridgeResponse.success(data: ["opened": false])
            }

            DispatchQueue.main.async {
                guard let presenter = Self.topViewController() else {
                    Pteal79Annotator.Session.failed(request, message: "Couldn't open the editor.")
                    return
                }
                let editor = AnnotatorViewController(request: request)
                editor.modalPresentationStyle = .fullScreen
                presenter.present(editor, animated: true)
            }

            return BridgeResponse.success(data: ["opened": true])
        }

        private static func string(_ value: Any?) -> String? {
            guard let value = value as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }

        /// The controller on top, so the editor shows over anything already presented.
        static func topViewController() -> UIViewController? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            let root = scene?.windows.first { $0.isKeyWindow }?.rootViewController
                ?? scene?.windows.first?.rootViewController

            var top = root
            while let presented = top?.presentedViewController {
                top = presented
            }
            return top
        }
    }
}

extension Pteal79Annotator {

    /// The one editor that may be open, and the single event it ends with.
    enum Session {
        static let eventSaved = "Pteal79\\ImageAnnotator\\Events\\ImageAnnotationSaved"
        static let eventCancelled = "Pteal79\\ImageAnnotator\\Events\\ImageAnnotationCancelled"
        static let eventFailed = "Pteal79\\ImageAnnotator\\Events\\ImageAnnotationFailed"

        static let messageAlreadyOpen = "already open"

        final class Request {
            let id: String
            let imagePath: String
            let originalPath: String?

            init(id: String, imagePath: String, originalPath: String?) {
                self.id = id
                self.imagePath = imagePath
                self.originalPath = originalPath
            }
        }

        private static let lock = NSLock()
        private static var current: Request?

        /// Returns false when an editor is already open.
        static func begin(_ request: Request) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if current != nil { return false }
            current = request
            return true
        }

        static func saved(_ owner: Request, outputPath: String, width: Int, height: Int, reverted: Bool) {
            finish(owner, eventSaved, [
                "outputPath": outputPath,
                "width": width,
                "height": height,
                "reverted": reverted,
            ])
        }

        static func cancelled(_ owner: Request) {
            finish(owner, eventCancelled, [:])
        }

        static func failed(_ owner: Request, message: String) {
            finish(owner, eventFailed, ["message": message])
        }

        /// Fails a request that never became the session (bad input, or already open).
        static func reject(id: String, message: String) {
            dispatch(eventFailed, ["id": id, "message": message])
        }

        /// Sends the session's single event. Calls for a request that is no
        /// longer the open one are ignored.
        private static func finish(_ owner: Request, _ event: String, _ payload: [String: Any]) {
            lock.lock()
            guard current === owner else {
                lock.unlock()
                return
            }
            current = nil
            lock.unlock()

            var body = payload
            body["id"] = owner.id
            dispatch(event, body)
        }

        /// Events go out on the main thread, after the editor has been dismissed.
        private static func dispatch(_ event: String, _ payload: [String: Any]) {
            let body: [String: Any?] = payload.mapValues { $0 as Any? }
            DispatchQueue.main.async {
                LaravelBridge.shared.send?(event, body)
            }
        }
    }
}
