//
//  CatalogView.swift
//  Discbot
//
//  Permanent disc catalog and rip-location history
//

import SwiftUI
import AppKit

struct CatalogView: View {
    private enum Section: String, CaseIterable {
        case library = "Library"
        case activity = "Activity"
        case statistics = "Statistics"
    }

    let catalogService: CatalogService

    @Environment(\.presentationMode) private var presentationMode
    @State private var entries: [CatalogEntry] = []
    @State private var selectedId: Int64?
    @State private var searchText = ""
    @State private var isLoading = false
    @State private var section: Section = .library
    @State private var statistics = CatalogStatistics.empty
    @State private var activity: [RipLogRecord] = []

    private var filteredEntries: [CatalogEntry] {
        guard !searchText.isEmpty else { return entries }
        let query = searchText.lowercased()
        return entries.filter { entry in
            entry.disc.displayName.lowercased().contains(query)
                || (entry.disc.artist?.lowercased().contains(query) == true)
                || entry.disc.fingerprint.lowercased().contains(query)
                || entry.rips.contains { $0.backupPath.lowercased().contains(query) }
        }
    }

    private var selectedEntry: CatalogEntry? {
        let id = selectedId ?? filteredEntries.first?.id
        return filteredEntries.first(where: { $0.id == id })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 520, idealHeight: 620)
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Disc Library")
                    .font(.title)
                    .fontWeight(.semibold)
                Text("Catalog, rip history, integrity, and collection statistics")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Picker("", selection: $section) {
                ForEach(Section.allCases, id: \.self) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .pickerStyle(SegmentedPickerStyle())
            .frame(width: 260)
            if section == .library {
                SearchFieldView(text: $searchText, placeholder: "Search library...")
                    .frame(width: 220, height: 24)
            }
            Button(action: reload) {
                if isLoading { SpinnerView(controlSize: .small).frame(width: 14, height: 14) }
                else { SFSymbol(name: "arrow.clockwise", size: 13) }
            }
            .disabled(isLoading)
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .library:
            HStack(spacing: 0) {
                catalogList.frame(width: 300)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .activity:
            activityView
        case .statistics:
            statisticsView
        }
    }

    private var catalogList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(filteredEntries.count) discs")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filteredEntries) { entry in
                        Button(action: { selectedId = entry.id }) {
                            catalogRow(entry)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(6)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func catalogRow(_ entry: CatalogEntry) -> some View {
        let selected = selectedEntry?.id == entry.id
        return HStack(spacing: 10) {
            SFSymbol(name: "opticaldisc", size: 20)
                .foregroundColor(entry.existingRips.isEmpty ? .secondary : .green)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.disc.displayName)
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("Seen \(entry.sightings.count)× · \(entry.rips.count) rip attempt\(entry.rips.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if !entry.existingRips.isEmpty {
                SFSymbol(name: "checkmark.circle.fill", size: 12).foregroundColor(.green)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var detail: some View {
        if let entry = selectedEntry {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    discSummary(entry)
                    sightingsSection(entry.sightings)
                    ripHistorySection(entry.rips)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 10) {
                SFSymbol(name: "opticaldisc", size: 40).foregroundColor(.secondary)
                Text(entries.isEmpty ? "No discs cataloged yet" : "Select a disc")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func discSummary(_ entry: CatalogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.disc.displayName).font(.title).fontWeight(.semibold)
            HStack(spacing: 8) {
                CapsuleBadge(text: discTypeLabel(entry.disc.discType), color: .blue)
                if entry.disc.hasReliableIdentity {
                    CapsuleBadge(text: "duplicate detection ready", color: .green)
                } else {
                    CapsuleBadge(text: "identity uncertain", color: .orange)
                }
            }
            Text("Fingerprint: \(entry.disc.fingerprint)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .textSelectionIfAvailable()
            if let size = entry.disc.sizeBytes {
                Text("Media size: \(formatBytes(size))").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func sightingsSection(_ sightings: [DiscSightingRecord]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sightings").font(.headline)
            if sightings.isEmpty {
                Text("No sighting history").foregroundColor(.secondary)
            } else {
                ForEach(sightings.prefix(20)) { sighting in
                    HStack {
                        Text("Slot \(sighting.slotId)").fontWeight(.medium)
                        Spacer()
                        Text(formatDate(sighting.seenDate)).foregroundColor(.secondary)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func ripHistorySection(_ rips: [BackupRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rip History").font(.headline)
            if rips.isEmpty {
                Text("This disc has not been ripped yet.").foregroundColor(.secondary)
            } else {
                ForEach(rips) { rip in ripRow(rip) }
            }
        }
    }

    private func ripRow(_ rip: BackupRecord) -> some View {
        let fileURL = URL(fileURLWithPath: rip.backupPath)
        let openURL = rip.preferredOpenURL
        let parentURL = fileURL.deletingLastPathComponent()
        let parentExists = FileManager.default.fileExists(atPath: parentURL.path)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                SFSymbol(name: ripStatusIcon(rip), size: 13)
                    .foregroundColor(ripStatusColor(rip))
                Text(rip.backupStatus.capitalized).fontWeight(.medium)
                if let slot = rip.slotId { Text("· Slot \(slot)").foregroundColor(.secondary) }
                Spacer()
                Text(formatDate(rip.backupDateParsed)).foregroundColor(.secondary)
            }
            .font(.caption)

            Text(rip.backupPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(rip.fileExists ? .primary : .secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            HStack {
                if let size = rip.backupSizeBytes { Text(formatBytes(size)).foregroundColor(.secondary) }
                if rip.isCompleted && !rip.fileExists {
                    CapsuleBadge(text: "file missing", color: .orange)
                }
                Spacer()
                if parentExists {
                    Button("Open Folder") { NSWorkspace.shared.open(parentURL) }
                }
                if rip.fileExists {
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                    Button("Open") { NSWorkspace.shared.open(openURL) }
                }
            }
            .font(.caption)

            if let error = rip.errorMessage, !error.isEmpty {
                Text(error).font(.caption).foregroundColor(rip.isReplaced ? .secondary : .red)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var footer: some View {
        HStack {
            Text("Duplicate skipping requires a reliable disc identity plus matching size and SHA-256.")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button("Close") { presentationMode.wrappedValue.dismiss() }
        }
        .padding(16)
    }

    private func reload() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = catalogService.getCatalogEntries()
            let loadedStatistics = catalogService.getStatistics()
            let loadedActivity = catalogService.getRecentRipLog()
            DispatchQueue.main.async {
                entries = loaded
                statistics = loadedStatistics
                activity = loadedActivity
                if selectedId == nil { selectedId = loaded.first?.id }
                isLoading = false
            }
        }
    }

    private var activityView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Rip Activity").font(.title).fontWeight(.semibold)
                    Spacer()
                    Text("Latest \(activity.count) events").font(.caption).foregroundColor(.secondary)
                }
                if activity.isEmpty {
                    emptyState(icon: "clock", title: "No ripping activity yet")
                } else {
                    ForEach(activity) { event in
                        HStack(alignment: .top, spacing: 12) {
                            SFSymbol(name: activityIcon(event.eventType), size: 15)
                                .foregroundColor(activityColor(event.eventType))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(event.eventType.capitalized).fontWeight(.medium)
                                    if let slot = event.slotId {
                                        Text("Slot \(slot)").foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Text(formatDate(event.eventDate)).foregroundColor(.secondary)
                                }
                                Text(event.message)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            }
                        }
                        .font(.caption)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    }
                }
            }
            .padding(24)
        }
    }

    private var statisticsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Collection Statistics").font(.title).fontWeight(.semibold)
                HStack(spacing: 12) {
                    statisticCard("Cataloged", value: "\(statistics.totalDiscs)", icon: "opticaldisc", color: .blue)
                    statisticCard("Available images", value: "\(statistics.availableImages)", icon: "checkmark.circle.fill", color: .green)
                    statisticCard("Stored", value: formatBytes(statistics.storedBytes), icon: "externaldrive.fill", color: .purple)
                }
                HStack(spacing: 12) {
                    statisticCard("Rip attempts", value: "\(statistics.ripAttempts)", icon: "arrow.triangle.2.circlepath", color: .blue)
                    statisticCard("Completed", value: "\(statistics.completedRips)", icon: "checkmark", color: .green)
                    statisticCard("Skipped", value: "\(statistics.skippedRips)", icon: "forward.fill", color: .orange)
                }
                HStack(spacing: 12) {
                    statisticCard("Failed", value: "\(statistics.failedRips)", icon: "exclamationmark.triangle.fill", color: .red)
                    statisticCard("Cancelled", value: "\(statistics.cancelledRips)", icon: "xmark.circle", color: .orange)
                    statisticCard("Replaced", value: "\(statistics.replacedRips)", icon: "arrow.clockwise", color: .purple)
                }
                HStack {
                    Text("Disc sightings").fontWeight(.medium)
                    Spacer()
                    Text("\(statistics.totalSightings)").font(.title).fontWeight(.semibold)
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            }
            .padding(24)
        }
    }

    private func statisticCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SFSymbol(name: icon, size: 18).foregroundColor(color)
            Text(value).font(.title).fontWeight(.semibold).lineLimit(1)
            Text(title).font(.caption).foregroundColor(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func emptyState(icon: String, title: String) -> some View {
        VStack(spacing: 10) {
            SFSymbol(name: icon, size: 32).foregroundColor(.secondary)
            Text(title).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    private func activityIcon(_ type: String) -> String {
        switch type {
        case "completed": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        case "cancelled": return "xmark.circle.fill"
        case "skipped": return "forward.fill"
        case "replaced": return "arrow.clockwise.circle.fill"
        default: return "play.circle.fill"
        }
    }

    private func activityColor(_ type: String) -> Color {
        switch type {
        case "completed": return .green
        case "failed": return .red
        case "cancelled", "skipped": return .orange
        case "replaced": return .purple
        default: return .blue
        }
    }

    private func formatBytes(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func formatDate(_ date: Date?) -> String {
        guard let date = date else { return "Unknown date" }
        let formatter = DateFormatter(); formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    private func discTypeLabel(_ type: String?) -> String { SlotDiscType.from(catalogString: type).label }
    private func ripStatusIcon(_ rip: BackupRecord) -> String {
        if rip.fileExists { return "checkmark.circle.fill" }
        if rip.isReplaced { return "arrow.clockwise.circle.fill" }
        if rip.isCompleted { return "exclamationmark.circle.fill" }
        if rip.isCancelled { return "xmark.circle.fill" }
        return "exclamationmark.triangle.fill"
    }
    private func ripStatusColor(_ rip: BackupRecord) -> Color {
        if rip.fileExists { return .green }
        if rip.isReplaced { return .purple }
        if rip.isCompleted { return .orange }
        return .red
    }
}

private extension View {
    @ViewBuilder
    func textSelectionIfAvailable() -> some View {
        if #available(macOS 12.0, *) { self.textSelection(.enabled) }
        else { self }
    }
}
