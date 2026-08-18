//
//  RipConfigSheet.swift
//  Discbot
//
//  Sheet for configuring disc imaging operation
//

import SwiftUI

struct RipConfigSheet: View {
    @EnvironmentObject private var viewModel: ChangerViewModel
    @Environment(\.presentationMode) var presentationMode

    @State private var outputDirectory: URL?
    @State private var duplicatePolicy: DuplicatePolicy = .skipExisting

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .padding()

            Divider()

            // Slot selection
            slotSelectionView
                .frame(maxHeight: 300)

            Divider()

            // Output folder selection
            outputFolderView
                .padding()

            duplicatePolicyView
                .padding(.horizontal)
                .padding(.bottom, 12)

            Divider()

            // Actions
            actionButtons
                .padding()
        }
        .frame(width: 520, height: 570)
    }

    private var headerView: some View {
        VStack(spacing: 8) {
            Text("Image Discs")
                .font(.headline)
            Text("Select discs to image and choose a destination folder")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var slotSelectionView: some View {
        VStack(spacing: 8) {
            // Selection controls
            HStack {
                Text("Select Discs")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                Button("Select All") {
                    viewModel.selectAllSlotsForRip()
                }
                .disabled(viewModel.rippableSlots.isEmpty)

                Button("Clear") {
                    viewModel.clearSlotSelectionForRip()
                }
                .disabled(viewModel.selectedSlotsForRip.isEmpty)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            // Slot list
            if viewModel.rippableSlots.isEmpty {
                VStack {
                    Spacer()
                    Text("No discs available to image")
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(viewModel.rippableSlots, id: \.id) { slot in
                            slotRow(slot)
                        }
                    }
                    .padding(.horizontal)
                }
            }

            // Selection count
            HStack {
                Text("\(viewModel.selectedSlotsForRip.count) of \(viewModel.rippableSlots.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private func slotRow(_ slot: Slot) -> some View {
        let isSelected = viewModel.selectedSlotsForRip.contains(slot.id)

        return Button(action: {
            viewModel.toggleSlotForRip(slot.id)
        }) {
            HStack {
                SFSymbol(name: isSelected ? "checkmark.circle.fill" : "circle", size: 16)
                    .foregroundColor(isSelected ? .accentColor : .secondary)

                Text("Slot \(slot.id)")
                    .foregroundColor(.primary)

                if case .backedUp = slot.backupStatus {
                    SFSymbol(name: "checkmark.circle.fill", size: 12)
                        .foregroundColor(.blue)
                }

                Spacer()

                if slot.hasException {
                    SFSymbol(name: "exclamationmark.triangle.fill", size: 12)
                        .foregroundColor(.orange)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(4)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var outputFolderView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Output Folder")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack {
                if let dir = outputDirectory {
                    SFSymbol(name: "folder.fill", size: 14)
                        .foregroundColor(.accentColor)
                    Text(dir.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No folder selected")
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Choose...") {
                    chooseOutputFolder()
                }
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(6)
        }
    }

    private var actionButtons: some View {
        HStack {
            Button("Cancel") {
                viewModel.clearSlotSelectionForRip()
                presentationMode.wrappedValue.dismiss()
            }

            Spacer()

            Button("Start Imaging") {
                if let dir = outputDirectory {
                    viewModel.startBatchImaging(outputDirectory: dir, duplicatePolicy: duplicatePolicy)
                    presentationMode.wrappedValue.dismiss()
                }
            }
            .disabled(viewModel.selectedSlotsForRip.isEmpty || outputDirectory == nil)
        }
    }

    private var duplicatePolicyView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Existing verified rip")
                .font(.subheadline)
                .fontWeight(.medium)
            Picker("", selection: $duplicatePolicy) {
                Text("Skip").tag(DuplicatePolicy.skipExisting)
                Text("Replace").tag(DuplicatePolicy.replaceExisting)
                Text("Keep Both").tag(DuplicatePolicy.imageAgain)
            }
            .pickerStyle(SegmentedPickerStyle())
            Text(duplicatePolicyDescription)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var duplicatePolicyDescription: String {
        switch duplicatePolicy {
        case .skipExisting:
            return "Skip only when the recorded size and SHA-256 still match."
        case .replaceExisting:
            return "Verify the new image before removing the previous copy; history is retained."
        case .imageAgain:
            return "Create another image and keep every existing copy."
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select a folder to save disc images"

        if panel.runModal() == .OK {
            outputDirectory = panel.url
        }
    }
}

#if DEBUG
struct RipConfigSheet_Previews: PreviewProvider {
    static var previews: some View {
        RipConfigSheet()
            .environmentObject(ChangerViewModel.preview)
    }
}
#endif
