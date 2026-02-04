//
//  BatchOperationSheet.swift
//  VGPChangerApp
//
//  Sheet showing batch operation progress
//

import SwiftUI

struct BatchOperationSheet: View {
    @ObservedObject var batchState: BatchOperationState
    let onCancel: () -> Void

    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        VStack(spacing: 24) {
            // Header
            headerSection

            // Progress
            progressSection

            // Status
            Text(batchState.statusText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(height: 20)

            // Imaging progress (if applicable)
            if case .imageAll = batchState.operationType, batchState.imagingProgress > 0 {
                imagingProgressSection
            }

            // Current metadata (if available)
            if let metadata = batchState.currentDiscMetadata {
                metadataSection(metadata: metadata)
            }

            // Errors
            if !batchState.failedSlots.isEmpty {
                errorsSection
            }

            Spacer()

            // Actions
            actionsSection
        }
        .padding(28)
        .frame(width: 420, height: 400)
    }

    private var headerSection: some View {
        VStack(spacing: 8) {
            SFSymbol(name: headerIcon, size: 36)
                .foregroundColor(.accentColor)

            Text(titleText)
                .font(.title)
                .fontWeight(.semibold)
        }
        .padding(.top, 8)
    }

    private var progressSection: some View {
        VStack(spacing: 12) {
            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 12)

                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * CGFloat(batchState.progress), height: 12)
                }
            }
            .frame(height: 12)

            HStack {
                HStack(spacing: 4) {
                    SFSymbol(name: "circle.fill", size: 10)
                        .foregroundColor(.secondary)
                    Text("Slot \(batchState.currentSlot)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(batchState.currentIndex) of \(batchState.totalCount)")
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var imagingProgressSection: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.green)
                        .frame(width: geometry.size.width * CGFloat(batchState.imagingProgress), height: 8)
                }
            }
            .frame(height: 8)

            Text("Imaging: \(Int(batchState.imagingProgress * 100))%")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func metadataSection(metadata: DiscMetadata) -> some View {
        VStack(spacing: 4) {
            Text(metadata.album)
                .font(.headline)
            if metadata.source != .slotNumber {
                Text(metadata.artist)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var errorsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                SFSymbol(name: "exclamationmark.triangle.fill", size: 14)
                    .foregroundColor(.red)
                Text("\(batchState.failedSlots.count) failed")
                    .font(.subheadline)
                    .foregroundColor(.red)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(batchState.failedSlots.indices, id: \.self) { index in
                        let failure = batchState.failedSlots[index]
                        HStack(spacing: 4) {
                            Text("Slot \(failure.slot):")
                                .fontWeight(.medium)
                            Text(failure.error)
                        }
                        .font(.caption)
                        .foregroundColor(.secondary)
                    }
                }
            }
            .frame(maxHeight: 60)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.red.opacity(0.1))
        )
    }

    private var actionsSection: some View {
        HStack(spacing: 12) {
            if batchState.isComplete || batchState.isCancelled {
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    Text("Close")
                        .frame(minWidth: 80)
                }
            } else {
                Button(action: { onCancel() }) {
                    Text("Cancel")
                        .frame(minWidth: 80)
                }
                .disabled(!batchState.isRunning)

                Text("Will stop after current disc")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var titleText: String {
        switch batchState.operationType {
        case .loadAll:
            return "Load All Discs"
        case .imageAll:
            return "Image All Discs"
        case nil:
            return "Batch Operation"
        }
    }

    private var headerIcon: String {
        switch batchState.operationType {
        case .loadAll:
            return "square.stack.3d.up"
        case .imageAll:
            return "doc.badge.gearshape"
        case nil:
            return "gearshape.2"
        }
    }
}

#if DEBUG
struct BatchOperationSheet_Previews: PreviewProvider {
    static var previews: some View {
        let state = BatchOperationState()
        state.operationType = .loadAll
        state.isRunning = true
        state.totalCount = 87
        state.currentIndex = 23
        state.currentSlot = 42
        state.statusText = "Loading slot 42..."
        state.completedSlots = Array(1...22)
        state.failedSlots = [(5, "Slot empty"), (12, "Move failed")]

        return BatchOperationSheet(batchState: state) {}
    }
}
#endif
