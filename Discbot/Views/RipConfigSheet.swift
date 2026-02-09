//
//  RipConfigSheet.swift
//  Discbot
//
//  Sheet for configuring disc ripping operation
//

import SwiftUI

struct RipConfigSheet: View {
    @EnvironmentObject private var viewModel: ChangerViewModel
    @Environment(\.presentationMode) var presentationMode

    @State private var outputDirectory: URL?

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

            Divider()

            // Actions
            actionButtons
                .padding()
        }
        .frame(width: 500, height: 500)
    }

    private var headerView: some View {
        VStack(spacing: 8) {
            Text("Rip Discs to ISO")
                .font(.headline)
            Text("Select discs to rip and choose a destination folder")
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
                    Text("No discs available to rip")
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

            Button("Start Ripping") {
                if let dir = outputDirectory {
                    // Signal MainView to start rip after this sheet dismisses
                    viewModel.pendingRipDirectory = dir
                    presentationMode.wrappedValue.dismiss()
                }
            }
            .disabled(viewModel.selectedSlotsForRip.isEmpty || outputDirectory == nil)
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Select a folder to save ISO images"

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
