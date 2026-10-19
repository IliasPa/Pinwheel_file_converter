import AppKit
import Observation
import SwiftUI

/// "Send Feedback…": a short message to Pinwheel's developer, with an email
/// address only if the sender wants to hear back. It goes through
/// formsubmit.co, which forwards it by email.
enum FeedbackSender {
    static let developer = "iliasparaskevas3@gmail.com"
    static let endpoint = URL(string: "https://formsubmit.co/ajax/\(developer)")!
    static let limit = 400

    enum Outcome: Equatable {
        case sent
        /// The form service is waiting for the developer to switch it on.
        case notActivated
        case failed(String)
    }

    /// "Pinwheel 1.1 · macOS 27.0.1": the only other thing that's sent.
    static var appInfo: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return "Pinwheel \(version) · macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
    }

    static func request(message: String, email: String, appInfo: String = appInfo) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // The service only takes messages that say where they come from.
        request.setValue(UpdateChecker.repository.absoluteString, forHTTPHeaderField: "Referer")
        var fields = [
            "_subject": "Pinwheel feedback",
            "_template": "table",
            "_captcha": "false",
            "message": message,
            "email": email.isEmpty ? "not given" : email,
            "app": appInfo,
        ]
        if !email.isEmpty { fields["_replyto"] = email }
        request.httpBody = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return request
    }

    /// Reads the service's answer: {"success": "true", "message": "…"}.
    static func outcome(data: Data, response: URLResponse) -> Outcome {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let success = (json["success"] as? String).map { $0 == "true" } ?? (json["success"] as? Bool ?? false)
        let message = json["message"] as? String ?? ""
        if status == 200 && success { return .sent }
        if message.localizedCaseInsensitiveContains("activat") { return .notActivated }
        return .failed(message.isEmpty ? "The message service answered with an error (\(status))." : message)
    }

    /// The same message as an email, for the sender's own mail app.
    static func mailURL(message: String, appInfo: String = appInfo) -> URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = developer
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Pinwheel feedback"),
            URLQueryItem(name: "body", value: "\(message)\n\n— \(appInfo)"),
        ]
        return components.url!
    }
}

@Observable
final class FeedbackModel {
    enum State: Equatable {
        case writing, sending, sent
        case notActivated
        case failed(String)
    }

    private(set) var text = ""
    var email: String
    private(set) var state = State.writing

    var onSent: ((_ email: String) -> Void)?
    var onClose: (() -> Void)?
    /// Sends a request (tests answer it themselves).
    @ObservationIgnored var post: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    init(email: String = "") {
        self.email = email
    }

    /// Keeps the message to the limit, even when something longer is pasted.
    func setText(_ newText: String) {
        text = String(newText.prefix(FeedbackSender.limit))
        if case .failed = state { state = .writing }
    }

    var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Empty is fine (it's optional); otherwise it has to look like an address.
    var emailIsValid: Bool {
        trimmedEmail.isEmpty || trimmedEmail.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]{2,}$"#, options: .regularExpression) != nil
    }

    var canSend: Bool {
        !trimmedText.isEmpty && emailIsValid && state != .sending && state != .sent
    }

    func send() async {
        guard canSend else { return }
        state = .sending
        let request = FeedbackSender.request(message: trimmedText, email: trimmedEmail)
        do {
            let (data, response) = try await post(request)
            switch FeedbackSender.outcome(data: data, response: response) {
            case .sent:
                state = .sent
                onSent?(trimmedEmail)
            case .notActivated:
                state = .notActivated
            case .failed(let reason):
                state = .failed(reason)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    var mailURL: URL { FeedbackSender.mailURL(message: trimmedText) }
}

struct FeedbackView: View {
    @Bindable var model: FeedbackModel

    var body: some View {
        Group {
            if model.state == .sent {
                thanks
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 470)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Send Feedback").font(.title3.weight(.semibold))
                    Text("An idea, a problem, or something you'd change? It goes straight to Pinwheel's developer.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .trailing, spacing: 4) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: Binding(get: { model.text }, set: { model.setText($0) }))
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                    if model.text.isEmpty {
                        Text("Write here…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.15)))
                Text("\(model.text.count) / \(FeedbackSender.limit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(model.text.count >= FeedbackSender.limit ? Color.orange : .secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                TextField("Your email (optional)", text: $model.email)
                    .textFieldStyle(.roundedBorder)
                Text(model.emailIsValid
                     ? "Add it to hear back: whether your idea was added, if it can't be done, or when work on it starts."
                     : "That doesn't look like an email address.")
                    .font(.caption)
                    .foregroundStyle(model.emailIsValid ? Color.secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            problem
            HStack {
                Text("Sent through formsubmit.co, with Pinwheel's and macOS's version and nothing else.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                Button("Cancel") { model.onClose?() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task { await model.send() }
                } label: {
                    if model.state == .sending {
                        ProgressView().controlSize(.small).frame(width: 40)
                    } else {
                        Text("Send")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSend)
            }
        }
    }

    @ViewBuilder
    private var problem: some View {
        switch model.state {
        case .notActivated, .failed:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(problemText).fixedSize(horizontal: false, vertical: true)
                    Button("Send It by Email Instead") { NSWorkspace.shared.open(model.mailURL) }
                        .controlSize(.small)
                }
            }
            .font(.callout)
        default:
            EmptyView()
        }
    }

    private var problemText: String {
        switch model.state {
        case .notActivated: "Feedback can't be received yet. Please send it by email instead."
        case .failed(let reason): "It couldn't be sent: \(reason)"
        default: ""
        }
    }

    private var thanks: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.green)
            Text("Thank you!").font(.title3.weight(.semibold))
            Text(model.trimmedEmail.isEmpty
                 ? "Your message was sent."
                 : "Your message was sent. You'll hear back at \(model.trimmedEmail).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Done") { model.onClose?() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }
}

final class FeedbackWindowController: EditorWindowController {
    init(model: FeedbackModel) {
        super.init(title: "Send Feedback", size: NSSize(width: 470, height: 420), resizable: false, content: FeedbackView(model: model))
        model.onClose = { [weak self] in self?.window?.close() }
    }

    func present() {
        NSApp.activate()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
