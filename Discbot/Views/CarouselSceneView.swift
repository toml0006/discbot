//
//  CarouselSceneView.swift
//  Discbot
//
//  NSViewRepresentable wrapper for the 3D carousel SCNView
//

import SwiftUI
import SceneKit

struct CarouselSceneView: NSViewRepresentable {
    let controller: CarouselSceneController
    var onSlotClicked: ((Int) -> Void)?
    var onSlotDoubleClicked: ((Int) -> Void)?
    var onArrowKey: ((ArrowDirection) -> Void)?
    var menuForSlot: ((Int) -> NSMenu?)?

    enum ArrowDirection { case left, right }

    func makeNSView(context: Context) -> CarouselHostView {
        let hostView = CarouselHostView(
            controller: controller,
            onSlotClicked: onSlotClicked,
            onSlotDoubleClicked: onSlotDoubleClicked,
            onArrowKey: onArrowKey,
            menuForSlot: menuForSlot
        )
        return hostView
    }

    func updateNSView(_ nsView: CarouselHostView, context: Context) {
        nsView.onSlotClicked = onSlotClicked
        nsView.onSlotDoubleClicked = onSlotDoubleClicked
        nsView.onArrowKey = onArrowKey
        nsView.menuForSlot = menuForSlot
    }
}

/// Custom NSView that hosts an SCNView and handles mouse events
class CarouselHostView: NSView {
    let scnView: SCNView
    let controller: CarouselSceneController
    var onSlotClicked: ((Int) -> Void)?
    var onSlotDoubleClicked: ((Int) -> Void)?
    var onArrowKey: ((CarouselSceneView.ArrowDirection) -> Void)?
    var menuForSlot: ((Int) -> NSMenu?)?

    init(controller: CarouselSceneController, onSlotClicked: ((Int) -> Void)?, onSlotDoubleClicked: ((Int) -> Void)?, onArrowKey: ((CarouselSceneView.ArrowDirection) -> Void)?, menuForSlot: ((Int) -> NSMenu?)?) {
        self.controller = controller
        self.onSlotClicked = onSlotClicked
        self.onSlotDoubleClicked = onSlotDoubleClicked
        self.onArrowKey = onArrowKey
        self.menuForSlot = menuForSlot
        self.scnView = SCNView()
        super.init(frame: .zero)

        scnView.scene = controller.scene
        scnView.backgroundColor = NSColor(white: 0.06, alpha: 1.0)
        scnView.antialiasingMode = .multisampling4X
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.showsStatistics = false

        addSubview(scnView)
        scnView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scnView.topAnchor.constraint(equalTo: topAnchor),
            scnView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scnView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scnView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Double-click gesture (must be added before single-click)
        let doubleClickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleDoubleClick(_:)))
        doubleClickGesture.numberOfClicksRequired = 2
        scnView.addGestureRecognizer(doubleClickGesture)

        // Click gesture
        let clickGesture = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        clickGesture.numberOfClicksRequired = 1
        scnView.addGestureRecognizer(clickGesture)

        // Mouse tracking
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        scnView.addTrackingArea(trackingArea)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: // Left arrow
            onArrowKey?(.left)
        case 124: // Right arrow
            onArrowKey?(.right)
        default:
            super.keyDown(with: event)
        }
    }

    // Become first responder on click so we receive key events
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    @objc private func handleClick(_ gesture: NSClickGestureRecognizer) {
        window?.makeFirstResponder(self)
        let point = gesture.location(in: scnView)
        if let slotId = controller.hitTestSlot(at: point, in: scnView) {
            onSlotClicked?(slotId)
        }
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        let point = gesture.location(in: scnView)
        if let slotId = controller.hitTestSlot(at: point, in: scnView) {
            onSlotDoubleClicked?(slotId)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = scnView.convert(event.locationInWindow, from: nil)
        if let slotId = controller.hitTestSlot(at: point, in: scnView),
           let menu = menuForSlot?(slotId) {
            NSMenu.popUpContextMenu(menu, with: event, for: scnView)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = scnView.convert(event.locationInWindow, from: nil)
        let slotId = controller.hitTestSlot(at: point, in: scnView)
        controller.hoverSlot(slotId)
    }
}
