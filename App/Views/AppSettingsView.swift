// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import KeePassCore

struct AppSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var languageChoice = AppLanguage.chosen ?? ""
    @State private var showRestartNotice = false

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        Picker("Clear clipboard after", selection: $settings.clipboardTimeout) {
                            ForEach(AppSettings.clipboardTimeoutOptions) { Text($0.label).tag($0.seconds) }
                        }
                        Toggle("Clear clipboard when locking", isOn: $settings.clearClipboardOnLock)
                        Picker("Lock in background after", selection: $settings.lockTimeout) {
                            ForEach(AppSettings.lockTimeoutOptions) { Text($0.label).tag($0.seconds) }
                        }
                        if BiometricKeyStore.isAvailable {
                            Toggle("Prompt for \(BiometricKeyStore.biometryName) automatically", isOn: $settings.autoPromptBiometrics)
                        }
                        Toggle("Remember key files", isOn: $settings.rememberKeyFiles)
                        Toggle("Show passwords by default", isOn: $settings.showPasswordsByDefault)
                        Toggle("Allow other keyboards", isOn: $settings.allowOtherKeyboards)
                    } header: {
                        Text("Security")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Copied items never sync to other devices via Universal Clipboard.")
                            Text("Other keyboards, including AI keyboards, can send what you type to their developers. When this is off, SaveKey always uses Apple’s keyboard. The change applies after you close SaveKey and open it again.")
                        }
                    }

                    Section {
                        Toggle("Hide during screen sharing", isOn: $settings.hideDuringScreenCapture)
                        if ScreenshotBlocking.isAvailable {
                            Toggle("Block screenshots", isOn: $settings.blockScreenshots)
                        }
                    } header: {
                        Text("Screen protection")
                    } footer: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("While the screen is recorded, mirrored, shared or controlled remotely, for example by an AI assistant, SaveKey shows only its logo.")
                            if ScreenshotBlocking.isAvailable {
                                Text("Screenshots of SaveKey come out blank, so Siri and other assistants that read the screen can’t see your passwords. On iOS 27.2 or later, you can also add SaveKey under Settings › Siri › Excluded Apps.")
                            }
                        }
                    }

                    Section {
                        Toggle("Copy one-time code after filling", isOn: $settings.autoFillCopiesOTP)
                        Toggle("Suggest logins in QuickType bar", isOn: $settings.quickTypeSuggestions)
                            .onChange(of: settings.quickTypeSuggestions) { enabled in
                                if !enabled { CredentialIdentities.removeAll() }
                            }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("To turn on Password AutoFill:").font(.subheadline.weight(.semibold))
                            Text("1. Open the Settings app")
                            Text("2. Go to General › AutoFill & Passwords")
                            Text("3. Turn on SaveKey")
                        }
                        .font(.subheadline)
                        .padding(.vertical, 4)
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    } header: {
                        Text("Password AutoFill")
                    } footer: {
                        Text("QuickType suggestions share usernames and website addresses (never passwords) with iOS so it can offer them above the keyboard. They update when you open or save a database.")
                    }

                    Section("Display") {
                        Picker("Appearance", selection: $settings.appearance) {
                            ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                        }
                        Toggle("Show Recycle Bin", isOn: $settings.showRecycleBin)
                        Picker("Sort entries by", selection: $settings.entrySort) {
                            ForEach(EntrySort.allCases) { Text($0.label).tag($0) }
                        }
                    }

                    Section {
                        Picker("Language", selection: Binding(get: { languageChoice }, set: { changeLanguage($0) })) {
                            Text("Same as iPhone").tag("")
                            ForEach(AppLanguage.supported, id: \.self) { code in
                                Text(AppLanguage.displayName(code)).tag(code)
                            }
                        }
                    } header: {
                        Text("Language")
                    } footer: {
                        Text("Changes the language of SaveKey only. You can also change it in iPhone Settings › Apps › SaveKey › Language.")
                    }

                    Section {
                        Toggle("Show website icons", isOn: $settings.showWebsiteIcons)
                        if settings.showWebsiteIcons {
                            Button("Delete downloaded icons", role: .destructive) {
                                WebsiteIconStore.shared.clearCache()
                            }
                        }
                    } header: {
                        Text("Website icons")
                    } footer: {
                        Text("Entries with a web address show that site's logo — for example the Netflix logo on a Netflix entry — instead of the standard icon. To get a logo, SaveKey connects to that website, which can see your IP address but nothing from your database. Logos are kept only on this iPhone. Entries with their own custom icon keep it.")
                    }

                    Section {
                        InfoRow(label: "Version", value: AppConfig.appVersion)
                        Text("SaveKey reads and writes standard KeePass databases (KDBX 3.1 and 4.x), compatible with KeePass, KeePassXC, KeePassDX and other KeePass apps.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("Passphrases use the EFF Large Wordlist, © Electronic Frontier Foundation, CC BY 3.0.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("About")
                    }

                    Section {
                        Text(verbatim: AppConfig.copyrightNotice)
                            .font(.footnote)
                        Text("SaveKey is free software: you can share and change it under the terms of the GNU Affero General Public License, version 3 or (at your option) any later version. It comes with absolutely no warranty.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text("The SaveKey logo is not covered by this license; all rights reserved.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Link(destination: AppConfig.licenseURL) {
                            Label("View the license", systemImage: "doc.text")
                        }
                        Link(destination: AppConfig.sourceCodeURL) {
                            Label("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        Link(destination: AppConfig.privacyPolicyURL) {
                            Label("Privacy policy", systemImage: "hand.raised")
                        }
                    } header: {
                        Text("License")
                    }
                }
                .themedRows()
            }
            .themedBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Restart SaveKey", isPresented: $showRestartNotice) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("To see SaveKey in the new language, close it (swipe it up in the app switcher) and open it again.")
            }
        }
    }

    /// Stores the language for SaveKey only (where iOS keeps its per-app language); used after a restart.
    private func changeLanguage(_ code: String) {
        guard code != languageChoice else { return }
        languageChoice = code
        AppLanguage.choose(code.isEmpty ? nil : code)
        showRestartNotice = true
    }
}
