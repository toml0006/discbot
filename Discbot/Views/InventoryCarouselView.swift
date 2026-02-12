//
//  InventoryCarouselView.swift
//  Discbot
//
//  SwiftUI container for the 3D carousel visualization
//

import SwiftUI

struct InventoryCarouselView: View {
    @EnvironmentObject private var viewModel: ChangerViewModel
    @State private var controller = CarouselSceneController()
    @State private var hasBuilt = false

    var body: some View {
        Group {
            if viewModel.slots.isEmpty {
                EmptyStateView(
                    icon: "bolt.horizontal.circle",
                    title: "Not Connected",
                    subtitle: "Waiting for changer connection...",
                    buttonTitle: "Retry Connection",
                    buttonIcon: "arrow.clockwise",
                    action: { viewModel.connect() }
                )
            } else {
                CarouselSceneView(
                    controller: controller,
                    onSlotClicked: { slotId in
                        viewModel.selectedSlotId = slotId
                        controller.rotateToSlot(slotId, duration: 0.6)
                    },
                    onSlotDoubleClicked: { slotId in
                        guard let slot = viewModel.slots.first(where: { $0.id == slotId }),
                              slot.isFull && !slot.isInDrive else { return }
                        viewModel.loadSlotWithEjectIfNeeded(slotId)
                    },
                    onArrowKey: { direction in
                        let slots = viewModel.slots
                        guard !slots.isEmpty else { return }
                        let currentId = viewModel.selectedSlotId ?? slots[0].id
                        let currentIndex = slots.firstIndex(where: { $0.id == currentId }) ?? 0
                        let newIndex: Int
                        switch direction {
                        case .left:
                            newIndex = currentIndex > 0 ? currentIndex - 1 : slots.count - 1
                        case .right:
                            newIndex = currentIndex < slots.count - 1 ? currentIndex + 1 : 0
                        }
                        let newId = slots[newIndex].id
                        viewModel.selectedSlotId = newId
                        controller.rotateToSlot(newId, duration: 0.4)
                    },
                    menuForSlot: { [viewModel] slotId in
                        guard let slot = viewModel.slots.first(where: { $0.id == slotId }) else { return nil }
                        return Self.buildContextMenu(for: slot, viewModel: viewModel)
                    }
                )
            }
        }
        .onAppear {
            if !hasBuilt && !viewModel.slots.isEmpty {
                controller.buildSlots(
                    slots: viewModel.slots,
                    driveStatus: viewModel.driveStatus,
                    selectedSlotId: viewModel.selectedSlotId
                )
                hasBuilt = true
            }
        }
        .onReceive(viewModel.$slots) { newSlots in
            guard !newSlots.isEmpty else { return }
            if !hasBuilt {
                controller.buildSlots(
                    slots: newSlots,
                    driveStatus: viewModel.driveStatus,
                    selectedSlotId: viewModel.selectedSlotId
                )
                hasBuilt = true
            } else {
                controller.updateSlotStates(
                    slots: newSlots,
                    selectedSlotId: viewModel.selectedSlotId
                )
            }
        }
        .onReceive(viewModel.$selectedSlotId) { newId in
            controller.highlightSlot(newId)
        }
        .onReceive(viewModel.$driveStatus) { newStatus in
            controller.updateDriveDisc(driveStatus: newStatus)
        }
        .onReceive(viewModel.$currentOperation) { operation in
            guard let operation = operation else { return }
            switch operation {
            case .loadingSlot(let slotId):
                controller.rotateToSlot(slotId)
                controller.animateLoadDisc(slotId: slotId)
            case .ejecting:
                if case .ejecting(let toSlot) = viewModel.driveStatus {
                    controller.rotateToSlot(toSlot)
                    controller.animateEjectDisc(toSlot: toSlot)
                }
            case .unloading(let slotId):
                controller.rotateToSlot(slotId)
                controller.animateEjectFromChamber(slotId: slotId)
            default:
                break
            }
        }
        .background(Color(NSColor(white: 0.06, alpha: 1.0)))
    }

    // MARK: - Context Menu Builder

    private static func buildContextMenu(for slot: Slot, viewModel: ChangerViewModel) -> NSMenu {
        let menu = NSMenu()
        let target = MenuActionTarget()
        // Retain the target for the lifetime of the menu
        objc_setAssociatedObject(menu, &menuTargetAssocKey, target, .OBJC_ASSOCIATION_RETAIN)

        // Header
        if slot.isFull || slot.isInDrive {
            let titleItem = NSMenuItem(title: slot.volumeLabel ?? "Disc from Slot \(slot.id)", action: nil, keyEquivalent: "")
            titleItem.isEnabled = false
            menu.addItem(titleItem)

            let typeItem = NSMenuItem(title: "\(slot.discType.label)  \u{00B7}  \(slot.discType.typicalSizeLabel)", action: nil, keyEquivalent: "")
            typeItem.isEnabled = false
            menu.addItem(typeItem)

            let statusItem = NSMenuItem(title: backupStatusLabel(slot.backupStatus), action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        } else {
            let emptyItem = NSMenuItem(title: "Slot \(slot.id) \u{2014} Empty", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        }

        menu.addItem(.separator())

        let canOperate = viewModel.currentOperation == nil
        let driveEmpty = viewModel.driveStatus == .empty

        // Load into Drive
        if slot.isFull && !slot.isInDrive {
            target.addItem(to: menu, title: "Load into Drive", enabled: canOperate && driveEmpty) {
                viewModel.loadSlot(slot.id)
            }
        }

        // Scan Disc
        if slot.isFull && !slot.isInDrive {
            target.addItem(to: menu, title: "Scan Disc", enabled: canOperate && driveEmpty) {
                viewModel.scanSlotDisc(slot.id)
            }
        }

        // Eject Disc (via I/E)
        if slot.isFull && !slot.isInDrive && viewModel.hasIESlot {
            target.addItem(to: menu, title: "Eject Disc", enabled: canOperate) {
                viewModel.unloadSlot(slot.id)
            }
        }

        // Load from I/E
        if !slot.isFull && !slot.isInDrive && viewModel.hasIESlot {
            target.addItem(to: menu, title: "Load from I/E", enabled: canOperate) {
                viewModel.importToSlot(slot.id)
            }
        }

        // Eject Here (drive disc to this slot)
        if !slot.isFull && !slot.isInDrive {
            if case .loaded = viewModel.driveStatus {
                target.addItem(to: menu, title: "Eject Here", enabled: canOperate) {
                    viewModel.ejectDisc(toSlot: slot.id)
                }
            }
        }

        return menu
    }

    private static func backupStatusLabel(_ status: BackupStatus) -> String {
        switch status {
        case .backedUp(let date):
            let f = DateFormatter()
            f.dateStyle = .short
            return "Imaged \(f.string(from: date))"
        case .failed:
            return "Imaging failed"
        case .notBackedUp:
            return "Not imaged"
        }
    }
}

// MARK: - Menu Action Helper

/// Key for associating MenuActionTarget with NSMenu
private var menuTargetAssocKey: UInt8 = 0

/// Target object that bridges NSMenuItem target-action to closures
private class MenuActionTarget: NSObject {
    private var actions: [Int: () -> Void] = [:]

    func addItem(to menu: NSMenu, title: String, enabled: Bool = true, action: @escaping () -> Void) {
        let index = actions.count
        actions[index] = action
        let item = NSMenuItem(
            title: title,
            action: enabled ? #selector(performAction(_:)) : nil,
            keyEquivalent: ""
        )
        item.target = self
        item.tag = index
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        actions[sender.tag]?()
    }
}
