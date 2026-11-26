// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import KeePassCore

struct PasswordGeneratorView: View {
    /// When set, a "Use" button returns the generated password.
    var onUse: ((String) -> Void)?

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var generated = ""

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            ColoredPasswordText(password: generated)
                                .font(.system(.title3, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { ToastCenter.shared.copied(generated, label: String(localized: "Password")) }
                            StrengthBar(bits: bits)
                            HStack {
                                Button {
                                    regenerate()
                                } label: {
                                    Label("Regenerate", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                                Button {
                                    ToastCenter.shared.copied(generated, label: String(localized: "Password"))
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    Section {
                        Picker("Type", selection: $settings.generatorUsesPassphrase) {
                            Text("Password").tag(false)
                            Text("Passphrase").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }

                    if settings.generatorUsesPassphrase {
                        passphraseOptions
                    } else {
                        passwordOptions
                    }
                }
                .themedRows()
            }
            .themedBackground()
            .navigationTitle("Generator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(onUse == nil ? "Done" : "Cancel") { dismiss() }
                }
                if let onUse {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Use") {
                            onUse(generated)
                            dismiss()
                        }
                        .bold()
                        .disabled(generated.isEmpty)
                    }
                }
            }
            .onAppear(perform: regenerate)
            .onChange(of: settings.passwordOptions) { _ in regenerate() }
            .onChange(of: settings.passphraseOptions) { _ in regenerate() }
            .onChange(of: settings.generatorUsesPassphrase) { _ in regenerate() }
        }
    }

    private var bits: Double {
        settings.generatorUsesPassphrase
            ? PasswordGenerator.entropy(settings.passphraseOptions)
            : PasswordStrength.estimateBits(generated)
    }

    private var passwordOptions: some View {
        Group {
            Section("Length: \(settings.passwordOptions.length)") {
                Slider(value: Binding(get: { Double(settings.passwordOptions.length) },
                                      set: { settings.passwordOptions.length = Int($0) }),
                       in: 4...128, step: 1)
            }
            Section("Characters") {
                Toggle("Uppercase (A–Z)", isOn: $settings.passwordOptions.uppercase)
                Toggle("Lowercase (a–z)", isOn: $settings.passwordOptions.lowercase)
                Toggle("Digits (0–9)", isOn: $settings.passwordOptions.digits)
                Toggle("Special (!#$%…)", isOn: $settings.passwordOptions.special)
                Toggle("Brackets ([]{}()<>)", isOn: $settings.passwordOptions.brackets)
                Toggle("Minus (-)", isOn: $settings.passwordOptions.minus)
                Toggle("Underscore (_)", isOn: $settings.passwordOptions.underline)
                Toggle("Space", isOn: $settings.passwordOptions.space)
                Toggle("Extended ASCII (é, ß, ¿…)", isOn: $settings.passwordOptions.extendedASCII)
            }
            Section {
                Toggle("Exclude look-alikes (O0Il1|…)", isOn: $settings.passwordOptions.excludeAmbiguous)
                Toggle("Use every selected group", isOn: $settings.passwordOptions.requireEveryGroup)
                TextField("Also include", text: $settings.passwordOptions.customCharacters)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Exclude", text: $settings.passwordOptions.excludedCharacters)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Advanced")
            }
        }
    }

    private var passphraseOptions: some View {
        Section("Passphrase") {
            Stepper("Words: \(settings.passphraseOptions.wordCount)",
                    value: $settings.passphraseOptions.wordCount, in: 3...12)
            HStack {
                Text("Separator")
                Spacer()
                TextField("-", text: $settings.passphraseOptions.separator)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            Picker("Capitalization", selection: $settings.passphraseOptions.capitalization) {
                Text("lowercase").tag(PassphraseOptions.Capitalization.lower)
                Text("Title Case").tag(PassphraseOptions.Capitalization.title)
                Text("UPPERCASE").tag(PassphraseOptions.Capitalization.upper)
            }
            Toggle("Add a digit", isOn: $settings.passphraseOptions.appendDigit)
            Text("Words from the EFF long word list (7,776 words, ~12.9 bits each).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func regenerate() {
        generated = settings.generatorUsesPassphrase
            ? PasswordGenerator.generatePassphrase(settings.passphraseOptions)
            : PasswordGenerator.generate(settings.passwordOptions)
    }
}
