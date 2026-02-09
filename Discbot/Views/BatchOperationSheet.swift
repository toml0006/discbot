//
//  BatchOperationSheet.swift
//  Discbot
//
//  Sheet showing batch operation progress
//

import SwiftUI

struct BatchOperationSheet: View {
    @ObservedObject var batchState: BatchOperationState

    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        VStack(spacing: 24) {
            // Header
            headerSection

            progressSection

            // Status
            Text(batchState.statusText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(height: 20)

            if case .imageAll = batchState.operationType {
                rippingStatsSection
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
        .frame(width: 460, height: 480)
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
            HStack {
                Text("Queue Progress")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(batchState.currentIndex) of \(batchState.totalCount)")
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }

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
            }
        }
    }

    private var rippingStatsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Current Disc")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Spacer()
                Text("\(Int(batchState.imagingProgress * 100))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

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

            if let name = batchState.currentDiscName, !name.isEmpty {
                Text(name)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Text("\(formatBytes(batchState.currentDiscTransferredBytes)) / \(formatBytes(batchState.currentDiscTotalBytes))")
                Spacer()
                Text("ETA: \(formatDuration(batchState.currentDiscETASeconds))")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            HStack {
                Text("Queue: \(formatBytes(batchState.overallTransferredBytes)) / \(formatBytes(batchState.overallEstimatedTotalBytes))")
                Spacer()
                Text("Queue ETA: \(formatDuration(batchState.overallETASeconds))")
            }
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
                if case .imageAll = batchState.operationType {
                    Button(action: {
                        batchState.isPaused ? batchState.resumeRip() : batchState.pauseRip()
                    }) {
                        Text(batchState.isPaused ? "Resume" : "Pause")
                            .frame(minWidth: 80)
                    }
                    .disabled(!batchState.isRunning)
                }

                Button(action: { batchState.cancel() }) {
                    Text("Cancel")
                        .frame(minWidth: 80)
                }
                .disabled(!batchState.isRunning)
            }
        }
    }

    private func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes = bytes else { return "Unknown" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ seconds: TimeInterval?) -> String {
        guard let seconds = seconds, seconds.isFinite, seconds > 0 else { return "Unknown" }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "Unknown"
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

        return BatchOperationSheet(batchState: state)
    }
}
#endif
