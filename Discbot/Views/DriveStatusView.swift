//
//  DriveStatusView.swift
//  Discbot
//
//  Shows device info and current drive status
//

import SwiftUI

struct DriveStatusView: View {
    @EnvironmentObject private var viewModel: ChangerViewModel

    var body: some View {
        HStack(spacing: 0) {
            // Device info
            deviceInfoSection

            Divider()
                .frame(height: 36)
                .padding(.horizontal, 20)

            // Drive status
            driveStatusSection

            Spacer()

            // Drive actions
            driveActions
        }
    }

    private var deviceInfoSection: some View {
        HStack(spacing: 12) {
            SFSymbol(name: "server.rack", size: 20)
                .foregroundColor(.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Device")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(viewModel.deviceDescription)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.medium)
            }
        }
        .frame(minWidth: 180, alignment: .leading)
    }

    private var driveStatusSection: some View {
        HStack(spacing: 12) {
            driveIcon
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text("Drive")
                    .font(.caption)
                    .foregroundColor(.secondary)
                driveStatusText
            }
        }
        .frame(minWidth: 200, alignment: .leading)
    }

    @ViewBuilder
    private var driveIcon: some View {
        switch viewModel.driveStatus {
        case .empty:
            SFSymbol(name: "circle.dashed", size: 20)
                .foregroundColor(.secondary)
        case .loading, .ejecting:
            SpinnerView(controlSize: .small)
                .frame(width: 20, height: 20)
        case .loaded:
            SFSymbol(name: "circle.fill", size: 20)
                .foregroundColor(.accentColor)
        case .error:
            SFSymbol(name: "exclamationmark.triangle.fill", size: 18)
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var driveStatusText: some View {
        switch viewModel.driveStatus {
        case .empty:
            Text("Empty")
                .font(.system(.body, design: .rounded))
                .fontWeight(.medium)
                .foregroundColor(.secondary)

        case .loading(let slot):
            Text("Loading slot \(slot)...")
                .font(.system(.body, design: .rounded))
                .fontWeight(.medium)

        case .loaded(let sourceSlot, let mountPoint):
            discNameText(sourceSlot: sourceSlot, mountPoint: mountPoint)

        case .ejecting(let slot):
            Text("Ejecting to slot \(slot)...")
                .font(.system(.body, design: .rounded))
                .fontWeight(.medium)

        case .error(let message):
            Text(message)
                .font(.system(.body, design: .rounded))
                .fontWeight(.medium)
                .foregroundColor(.red)
                .lineLimit(1)
        }
    }

    private func discNameText(sourceSlot: Int, mountPoint: String?) -> some View {
        HStack(spacing: 6) {
            // Show volume name if mounted, otherwise "Disc from Slot X"
            if let mount = mountPoint {
                Text(volumeName(from: mount))
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.medium)
            } else {
                Text("Disc from Slot \(sourceSlot)")
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.medium)
            }

            CapsuleBadge(
                text: mountPoint != nil ? "mounted" : "unmounted",
                color: mountPoint != nil ? .green : .orange
            )
        }
    }

    private func volumeName(from mountPoint: String) -> String {
        // Extract volume name from mount point like "/Volumes/DISC_NAME"
        let components = mountPoint.split(separator: "/")
        if let last = components.last {
            return String(last)
        }
        return mountPoint
    }

    @ViewBuilder
    private var driveActions: some View {
        HStack(spacing: 8) {
            // Import button (import from I/E slot)
            if viewModel.hasIESlot {
                Button(action: { viewModel.importFromIESlot() }) {
                    HStack(spacing: 4) {
                        SFSymbol(name: "arrow.down.circle", size: 12)
                        Text("Import")
                    }
                }
                .disabled(!canImport)
                .helpTooltip("Import disc from I/E slot into the drive")
            }

            // Eject button
            switch viewModel.driveStatus {
            case .loaded:
                Button(action: { viewModel.ejectDisc() }) {
                    HStack(spacing: 4) {
                        SFSymbol(name: "eject", size: 12)
                        Text("Eject")
                    }
                }
                .helpTooltip("Unmount and return disc to its slot")

            case .empty:
                Button(action: {}) {
                    HStack(spacing: 4) {
                        SFSymbol(name: "eject", size: 12)
                        Text("Eject")
                    }
                }
                .disabled(true)

            default:
                EmptyView()
            }
        }
        .disabled(viewModel.currentOperation != nil)
    }

    private var canImport: Bool {
        guard viewModel.currentOperation == nil else { return false }
        guard case .empty = viewModel.driveStatus else { return false }
        return true
    }
}

#if DEBUG
struct DriveStatusView_Previews: PreviewProvider {
    static var previews: some View {
        DriveStatusView()
            .environmentObject(ChangerViewModel.preview)
            .padding()
    }
}
#endif
