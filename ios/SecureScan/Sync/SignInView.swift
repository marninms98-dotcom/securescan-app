//
//  SignInView.swift
//  SecureScan
//
//  "Sign in with your SecureSuite account": email, password, one primary
//  button, one plain line when something is wrong, and a quiet way to use
//  the app without an account (jobs then stay on this iPhone). Shown on
//  first launch when sync is configured, and from Settings.
//

import SwiftUI

struct SignInView: View {
    /// Called after signing in or choosing to go on without (the presenter closes the screen).
    let onDone: () -> Void
    /// The first-launch screen offers "Use without signing in"; from Settings it is "Cancel".
    var fromSettings = false

    @ObservedObject private var center = SyncCenter.shared
    @State private var email = ""
    @State private var password = ""
    @State private var problem: String?
    @State private var busy = false
    @FocusState private var focus: Field?

    enum Field { case email, password }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                mark
                    .padding(.bottom, 24)
                Text("Sign in")
                    .font(DS.Font.title)
                Text("Sign in with your SecureSuite account")
                    .font(DS.Font.callout)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
                fields
                    .padding(.top, 28)
                problemLine
                    .padding(.top, 10)
            }
            .padding(.horizontal, DS.Space.margin)
            .padding(.top, fromSettings ? 24 : 64)
            .frame(maxWidth: 480, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) { dock }
        .onAppear(perform: prefillForScreenshots)
        .interactiveDismissDisabled(busy)
    }

    /// The app's mark: one accent tile.
    private var mark: some View {
        Image(systemName: "viewfinder")
            .font(.system(size: 28, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 60, height: 60)
            .background(DS.Color.accent, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .accessibilityHidden(true)
    }

    private var fields: some View {
        VStack(spacing: 0) {
            TextField("Email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .email)
                .onSubmit { focus = .password }
                .padding(.horizontal, DS.Space.margin)
                .frame(height: 52)
            Divider().padding(.leading, DS.Space.margin)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focus, equals: .password)
                .onSubmit(submit)
                .padding(.horizontal, DS.Space.margin)
                .frame(height: 52)
        }
        .font(DS.Font.body)
        .background(Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .disabled(busy)
        .onChange(of: email) { _, _ in problem = nil }
        .onChange(of: password) { _, _ in problem = nil }
    }

    /// Always the same height, so the screen does not jump when a problem appears.
    private var problemLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let problem {
                Image(systemName: "exclamationmark.circle.fill")
                Text(problem).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(DS.Font.captionBold)
        .foregroundStyle(DS.Color.wet)
        .frame(minHeight: 18, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var dock: some View {
        VStack(spacing: 4) {
            PrimaryButton(busy ? "Signing in…" : "Sign in", enabled: !busy, action: submit)
            Button(fromSettings ? "Cancel" : "Use without signing in") {
                if !fromSettings { center.skipSignIn() }
                onDone()
            }
            .font(DS.Font.calloutBold)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: DS.Size.minTarget)
            .contentShape(Rectangle())
            .disabled(busy)
        }
        .padding(.horizontal, DS.Space.margin)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(Color(.systemGroupedBackground).ignoresSafeArea(edges: .bottom))
    }

    private func submit() {
        guard !busy else { return }
        if let p = SyncWords.validateSignIn(email: email, password: password) {
            problem = p
            DS.Haptic.warning()
            return
        }
        focus = nil
        busy = true
        Task {
            let result = await center.signIn(email: email, password: password)
            busy = false
            if let result {
                problem = result
                DS.Haptic.warning()
            } else {
                DS.Haptic.save()
                onDone()
            }
        }
    }

    private func prefillForScreenshots() {
        #if DEBUG
        if center.fake == .signInError && email.isEmpty {
            email = "jordan.lee@example.com"
            password = "not-the-password"
            Task {
                try? await Task.sleep(nanoseconds: 200_000_000)
                problem = await center.signIn(email: email, password: password)
            }
        }
        #endif
    }
}
