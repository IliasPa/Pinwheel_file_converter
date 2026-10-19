import Foundation
import Testing
@testable import PinwheelUI

struct FeedbackTests {
    private func answer(_ status: Int, _ body: String) -> (URLRequest) async throws -> (Data, URLResponse) {
        { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func atMost400CharactersAndAnOptionalEmail() {
        let model = FeedbackModel()
        #expect(!model.canSend, "nothing written yet")
        model.setText(String(repeating: "α", count: 450))
        #expect(model.text.count == 400)
        model.setText("   ")
        #expect(!model.canSend, "spaces only")
        model.setText("Please add WebP")
        #expect(model.canSend && model.emailIsValid)
        model.email = "not an address"
        #expect(!model.emailIsValid && !model.canSend)
        model.email = " me@example.com "
        #expect(model.emailIsValid && model.trimmedEmail == "me@example.com")
    }

    @Test func theMessageGoesToTheDeveloper() throws {
        let request = FeedbackSender.request(message: "Please add WebP", email: "me@example.com", appInfo: "Pinwheel 1.1 · macOS 27.0")
        #expect(request.url?.absoluteString == "https://formsubmit.co/ajax/iliasparaskevas3@gmail.com")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        let fields = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        #expect(fields["message"] == "Please add WebP")
        #expect(fields["email"] == "me@example.com")
        #expect(fields["_replyto"] == "me@example.com")
        #expect(fields["app"] == "Pinwheel 1.1 · macOS 27.0")
        #expect(fields["_subject"] == "Pinwheel feedback")

        let anonymous = FeedbackSender.request(message: "Hi", email: "")
        let anonymousFields = try #require(try JSONSerialization.jsonObject(with: anonymous.httpBody ?? Data()) as? [String: String])
        #expect(anonymousFields["email"] == "not given")
        #expect(anonymousFields["_replyto"] == nil)
    }

    @Test func whatTheServiceAnswersIsShown() async {
        let model = FeedbackModel(email: "me@example.com")
        var remembered: String?
        model.onSent = { remembered = $0 }
        model.setText("Please add WebP")

        model.post = answer(200, #"{"success":"false","message":"This form needs Activation. We've sent you an email containing an 'Activate Form' link."}"#)
        await model.send()
        #expect(model.state == .notActivated)

        model.post = answer(500, "oops")
        await model.send()
        #expect(model.state == .failed("The message service answered with an error (500)."))

        model.post = { _ in throw URLError(.notConnectedToInternet) }
        await model.send()
        if case .failed = model.state {} else { Issue.record("expected a failure, got \(model.state)") }

        model.post = answer(200, #"{"success":"true","message":"The form was submitted successfully."}"#)
        await model.send()
        #expect(model.state == .sent)
        #expect(remembered == "me@example.com")
        #expect(!model.canSend, "sent once")
    }

    @Test func emailInsteadKeepsTheMessage() throws {
        let url = FeedbackSender.mailURL(message: "Ναι & όχι?", appInfo: "Pinwheel 1.1")
        #expect(url.scheme == "mailto")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "iliasparaskevas3@gmail.com")
        let body = components.queryItems?.first(where: { $0.name == "body" })?.value
        #expect(body == "Ναι & όχι?\n\n— Pinwheel 1.1")
    }
}
