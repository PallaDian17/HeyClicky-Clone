import AppKit
import SwiftUI

@MainActor
final class SignInWindowController {
    let window: NSWindow
    private let auth: AuthManager

    init(auth: AuthManager) {
        self.auth = auth
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 440),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign in"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SignInView(auth: auth))
        window.center()
        auth.presentationWindow = window
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window.close() }
}

struct SignInView: View {
    @ObservedObject var auth: AuthManager
    @State private var email = ""
    @State private var password = ""
    @State private var creating = false

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                EyesView(mood: .awake)
                    .scaleEffect(1.6)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 14).fill(.black))
                Text(creating ? "Create your account" : "Welcome back")
                    .font(.title2.weight(.semibold))
                Text("Your Clickys, routines and settings follow this account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            VStack(spacing: 10) {
                TextField("Email", text: $email)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(creating ? .newPassword : .password)
                    .onSubmit(submit)
            }
            .textFieldStyle(.roundedBorder)

            Button(action: submit) {
                Text(creating ? "Create account" : "Sign in")
                    .frame(maxWidth: .infinity)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(auth.isBusy || email.isEmpty || password.count < 6)

            HStack {
                Rectangle().fill(.quaternary).frame(height: 1)
                Text("or").font(.caption).foregroundStyle(.secondary)
                Rectangle().fill(.quaternary).frame(height: 1)
            }

            Button {
                Task { await auth.signInWithGoogle() }
            } label: {
                Label("Continue with Google", systemImage: "globe")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(auth.isBusy)

            Group {
                if let error = auth.errorMessage {
                    Text(error).foregroundStyle(.red)
                } else if let info = auth.infoMessage {
                    Text(info).foregroundStyle(.secondary)
                } else if auth.isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .font(.callout)
            .multilineTextAlignment(.center)
            .frame(minHeight: 36)

            Spacer(minLength: 0)

            Button(creating ? "Have an account? Sign in" : "New here? Create an account") {
                creating.toggle()
                auth.errorMessage = nil
                auth.infoMessage = nil
            }
            .buttonStyle(.link)
            .font(.callout)
        }
        .padding(28)
        .frame(width: 380, height: 440)
    }

    private func submit() {
        guard !auth.isBusy, !email.isEmpty, password.count >= 6 else { return }
        Task {
            if creating {
                await auth.signUp(email: email, password: password)
            } else {
                await auth.signIn(email: email, password: password)
            }
        }
    }
}
