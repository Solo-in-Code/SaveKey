// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import PhotosUI
import KeePassCore

struct IconPickerView: View {
    @Binding var iconID: Int
    @Binding var customIconUUID: UUID?
    /// Set when choosing an icon for a group (folders and entries use the same colours).
    var isGroup = false
    @EnvironmentObject private var session: DatabaseSession
    @Environment(\.dismiss) private var dismiss
    @State private var photoItem: PhotosPickerItem?
    @State private var loadError: String?

    private let columns = [GridItem(.adaptive(minimum: 52), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !session.database.meta.customIcons.isEmpty {
                        Text("Custom icons").font(.headline)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(session.database.meta.customIcons) { icon in
                                Button {
                                    customIconUUID = icon.uuid
                                    dismiss()
                                } label: {
                                    KeePassIconView(iconID: 0, customIcon: icon, size: 48, isGroup: isGroup)
                                        .overlay(selectionRing(customIconUUID == icon.uuid))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !session.isReadOnly {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label("Add custom icon from Photos", systemImage: "photo.badge.plus")
                        }
                    }
                    Text("Standard icons").font(.headline)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(0..<KeePassIcons.symbols.count, id: \.self) { id in
                            Button {
                                iconID = id
                                customIconUUID = nil
                                dismiss()
                            } label: {
                                KeePassIconView(iconID: id, size: 48, isGroup: isGroup)
                                    .overlay(selectionRing(customIconUUID == nil && iconID == id))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Icon")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task { await importPhoto(item) }
            }
            .alert("Could not add icon", isPresented: Binding(get: { loadError != nil }, set: { if !$0 { loadError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(loadError ?? "")
            }
        }
    }

    private func selectionRing(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(selected ? Color.accentColor : .clear, lineWidth: 3)
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let png = image.resizedToFit(maxSide: 128).pngData() else {
                loadError = String(localized: "The image could not be read.")
                return
            }
            let icon = CustomIcon(data: png)
            session.database.meta.customIcons.append(icon)
            customIconUUID = icon.uuid
            session.refresh()
            photoItem = nil
            dismiss()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

extension UIImage {
    func resizedToFit(maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(size.width, size.height))
        let newSize = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
