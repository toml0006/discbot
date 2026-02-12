//
//  OperationProgressView.swift
//  Discbot
//
//  Overlay shown during long-running operations
//

import SwiftUI

struct OperationProgressView: View {
    let operation: ChangerViewModel.Operation
    let statusText: String

    var body: some View {
        VStack(spacing: 20) {
            // Icon or spinner
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.1))
                    .frame(width: 72, height: 72)

                if isSpinnerOperation {
                    SpinnerView(controlSize: .regular)
                        .frame(width: 36, height: 36)
                } else {
                    SFSymbol(name: operationIcon, size: 32)
                        .foregroundColor(.accentColor)
                }
            }

            VStack(spacing: 8) {
                Text(operationTitle)
                    .font(.headline)
                    .fontWeight(.semibold)

                Text(statusText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .padding(40)
        .frame(minWidth: 280)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var isSpinnerOperation: Bool {
        switch operation {
        case .waitingForDiscRemoval:
            return false
        default:
            return true
        }
    }

    private var operationIcon: String {
        switch operation {
        case .connecting:
            return "bolt.horizontal.circle"
        case .loadingSlot:
            return "arrow.right.circle"
        case .ejecting:
            return "arrow.uturn.backward"
        case .mounting:
            return "play.fill"
        case .unmounting:
            return "eject"
        case .scanning:
            return "magnifyingglass"
        case .refreshing:
            return "arrow.clockwise"
        case .unloading:
            return "tray.and.arrow.up"
        case .scanningSlot:
            return "magnifyingglass.circle"
        case .waitingForDiscRemoval:
            return "hand.point.down.fill"
        }
    }

    private var operationTitle: String {
        switch operation {
        case .connecting:
            return "Connecting"
        case .loadingSlot(let slot):
            return "Loading Slot \(slot)"
        case .ejecting:
            return "Ejecting to Slot"
        case .mounting:
            return "Mounting"
        case .unmounting:
            return "Unmounting"
        case .scanning:
            return "Scanning Inventory"
        case .refreshing:
            return "Refreshing"
        case .unloading(let slot):
            return "Ejecting Disc \(slot)"
        case .scanningSlot(let slot):
            return "Scanning Slot \(slot)"
        case .waitingForDiscRemoval:
            return "Remove Disc"
        }
    }
}

#if DEBUG
struct OperationProgressView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.gray.opacity(0.3)
            OperationProgressView(
                operation: .loadingSlot(42),
                statusText: "Loading disc from slot 42..."
            )
        }
    }
}
#endif
