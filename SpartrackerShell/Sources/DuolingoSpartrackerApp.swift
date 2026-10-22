import UIKit
import WebKit
import UniformTypeIdentifiers

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = TrackerViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}

private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class TrackerViewController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate,
    UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private var webView: WKWebView!
    private var webRoot: URL?
    private var store: TrackerBackupStore?
    private let client = DuolingoClient()
    private var timer: Timer?
    private var pageReady = false
    private var requests: [String: Task<Void, Never>] = [:]
    private var pickerRequest: String?
    private var sharing = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 247/255, green: 248/255, blue: 244/255, alpha: 1)
        let initial: String?
        do {
            let value = try TrackerBackupStore()
            store = value
            initial = value.initialState()
        } catch { initial = "storage-unavailable" }
        let payload: [String: Any] = ["stored": initial.map { $0 as Any } ?? NSNull()]
        let bootstrap = (try? JSONSerialization.data(withJSONObject: payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{\"stored\":null}"
        let controller = WKUserContentController()
        controller.add(WeakScriptHandler(self), name: "duospar")
        controller.addUserScript(WKUserScript(source: "window.__duoInitialState = (\(bootstrap)).stored;",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = view.backgroundColor
        webView.scrollView.backgroundColor = view.backgroundColor
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = false
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(startPolling),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(stopPolling),
            name: UIApplication.willResignActiveNotification, object: nil)
        guard let index = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") else {
            showLoadError(); return
        }
        webRoot = index.deletingLastPathComponent().standardizedFileURL
        webView.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
    }

    deinit { timer?.invalidate(); NotificationCenter.default.removeObserver(self) }

    private func showLoadError() {
        let label = UILabel()
        label.text = "Die App konnte nicht geladen werden. Bitte öffne sie erneut."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.frame = view.bounds.insetBy(dx: 24, dy: 24)
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        startPolling()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.isFileURL, let root = webRoot,
              url.standardizedFileURL.path.hasPrefix(root.path + "/"),
              navigationAction.targetFrame?.isMainFrame == true else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    @objc private func startPolling() {
        guard pageReady, UIApplication.shared.applicationState == .active else { return }
        timer?.invalidate()
        tick()
        let value = Timer(timeInterval: 5, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        timer = value
        RunLoop.main.add(value, forMode: .common)
    }

    @objc private func stopPolling() {
        timer?.invalidate(); timer = nil
        for (id, task) in requests {
            task.cancel()
            reply(id, status: 503, data: ["error": "Die App wurde pausiert. Beim Öffnen wird erneut geprüft."])
        }
        requests.removeAll()
    }

    @objc private func tick() {
        guard pageReady, UIApplication.shared.applicationState == .active else { return }
        send(["type": "refresh-tick"])
    }

    private func send(_ payload: [String: Any]) {
        webView.callAsyncJavaScript("window.__duoNativeReceive && window.__duoNativeReceive(message)",
            arguments: ["message": payload], in: nil, in: .page, completionHandler: nil)
    }

    private func reply(_ id: String, status: Int = 200, data: [String: Any]) {
        send(["id": id, "status": status, "data": data])
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let url = message.frameInfo.request.url?.standardizedFileURL,
              let root = webRoot, url.path.hasPrefix(root.path + "/"),
              let value = message.body as? [String: Any],
              let id = value["id"] as? String, id.utf8.count <= 100,
              let type = value["type"] as? String else { return }
        switch type {
        case "duolingo":
            guard let username = value["username"] as? String, username.utf16.count <= 80 else {
                reply(id, status: 400, data: ["error": "Ungültiger Benutzername."]); return
            }
            guard UIApplication.shared.applicationState == .active else {
                reply(id, status: 503, data: ["error": "Öffne die App, um deine XP zu aktualisieren."]); return
            }
            guard requests.isEmpty else {
                reply(id, status: 409, data: ["error": "Dein Profil wird bereits geprüft."]); return
            }
            requests[id] = Task { [weak self] in
                guard let self else { return }
                defer { self.requests.removeValue(forKey: id) }
                do {
                    let profile = try await self.client.fetch(username: username)
                    try Task.checkCancellation()
                    let data = try JSONEncoder().encode(profile)
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        throw DuolingoClientError.invalidResponse
                    }
                    self.reply(id, data: object)
                } catch is CancellationError { /* stopPolling already completes the pending JS request */ }
                catch let error as DuolingoClientError {
                    self.reply(id, status: error.statusCode, data: ["error": error.localizedDescription])
                } catch {
                    self.reply(id, status: 502, data: ["error": "Duolingo ist gerade nicht erreichbar. Dein letzter Stand bleibt erhalten."])
                }
            }
        case "store":
            do {
                guard let json = value["data"] as? String, let store else { throw BackupError.unavailable }
                try store.save(json)
                reply(id, data: ["completed": true])
            } catch { reply(id, status: 500, data: ["error": error.localizedDescription]) }
        case "export":
            guard let json = value["data"] as? String else {
                reply(id, status: 400, data: ["error": BackupError.invalid.localizedDescription]); return
            }
            exportBackup(json, id: id)
        case "import": openBackupPicker(id: id)
        default: reply(id, status: 400, data: ["error": "Diese Aktion wird nicht unterstützt."])
        }
    }

    private func exportBackup(_ json: String, id: String) {
        guard presentedViewController == nil, !sharing else {
            reply(id, status: 409, data: ["error": "Schließe zuerst das offene Fenster."]); return
        }
        do {
            let data = try TrackerBackupStore.validate(json)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("Duolingo-Spartracker-Sicherung.json")
            try data.write(to: file, options: .atomic)
            let activity = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = view
            activity.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            sharing = true
            activity.completionWithItemsHandler = { [weak self] _, completed, _, error in
                Task { @MainActor in
                    self?.sharing = false
                    if let error { self?.reply(id, status: 500, data: ["error": error.localizedDescription]) }
                    else { self?.reply(id, data: ["completed": completed]) }
                    try? FileManager.default.removeItem(at: directory)
                }
            }
            present(activity, animated: true)
        } catch { reply(id, status: 400, data: ["error": error.localizedDescription]) }
    }

    private func openBackupPicker(id: String) {
        guard presentedViewController == nil, pickerRequest == nil else {
            reply(id, status: 409, data: ["error": "Schließe zuerst das offene Fenster."]); return
        }
        pickerRequest = id
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
        picker.presentationController?.delegate = self
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let id = pickerRequest else { return }
        pickerRequest = nil
        guard let url = urls.first else { reply(id, data: ["json": NSNull()]); return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= TrackerBackupStore.maximumBytes else { throw BackupError.tooLarge }
            let data = try Data(contentsOf: url)
            guard data.count <= TrackerBackupStore.maximumBytes else { throw BackupError.tooLarge }
            guard let json = String(data: data, encoding: .utf8) else { throw BackupError.invalid }
            try TrackerBackupStore.validate(json)
            reply(id, data: ["json": json])
        } catch { reply(id, status: 400, data: ["error": error.localizedDescription]) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cancelPicker() }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { cancelPicker() }
    private func cancelPicker() {
        guard let id = pickerRequest else { return }
        pickerRequest = nil
        reply(id, data: ["json": NSNull()])
    }
}
