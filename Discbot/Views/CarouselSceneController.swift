//
//  CarouselSceneController.swift
//  Discbot
//
//  SceneKit scene controller for the 3D carousel visualization
//
//  Real-world dimensions (scaled):
//    Disc: 120mm diameter, 15mm center hole, 1.2mm thick
//    Drive: 128mm × 129mm × 12.7mm (slot-loading, on its side)
//

import SceneKit
import AppKit

class CarouselSceneController {
    let scene = SCNScene()

    // Key nodes
    private(set) var carouselPivotNode = SCNNode()
    private(set) var driveNode = SCNNode()
    private var cameraNode = SCNNode()

    // Slot tracking
    private var slotNodes: [Int: SCNNode] = [:]   // slotId -> slot group node
    private var discNodes: [Int: SCNNode] = [:]    // slotId -> disc node
    private var driveDiscNode: SCNNode?
    private var selectedLabelNode: SCNNode?

    // State
    private var highlightedSlotId: Int?
    private var hoveredSlotId: Int?
    private(set) var animatingSlotIds: Set<Int> = []

    // Geometry constants (scene units; 1.5 units = 60mm real)
    private let carouselRadius: CGFloat = 5.0
    private let slotCount = 200
    private let discRadius: CGFloat = 1.5       // 60mm
    private let discHoleRadius: CGFloat = 0.1875 // 7.5mm (15mm hole / 2), 12.5% of disc radius
    private let discThickness: CGFloat = 0.015   // 1.2mm (slightly thicker for visibility)

    // Drive dimensions on its side (128×129×12.7mm scaled)
    private let driveWidth: CGFloat = 0.32       // 12.7mm (thin, on its side)
    private let driveHeight: CGFloat = 3.2       // 128mm
    private let driveDepth: CGFloat = 3.23       // 129mm

    init() {
        setupScene()
    }

    // MARK: - Scene Setup

    private func setupScene() {
        scene.background.contents = NSColor(white: 0.06, alpha: 1.0)

        // Camera — elevated 3/4 view
        let camera = SCNCamera()
        camera.fieldOfView = 45
        camera.zNear = 0.1
        camera.zFar = 100
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 12, 14)
        cameraNode.look(at: SCNVector3(0, 0.5, 0))
        scene.rootNode.addChildNode(cameraNode)

        // Ambient light
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light!.type = .ambient
        ambientLight.light!.color = NSColor(white: 0.35, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)

        // Directional light from above-front
        let dirLight = SCNNode()
        dirLight.light = SCNLight()
        dirLight.light!.type = .directional
        dirLight.light!.color = NSColor(white: 0.6, alpha: 1.0)
        dirLight.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 6, 0)
        scene.rootNode.addChildNode(dirLight)

        // Secondary fill from below-back
        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light!.type = .directional
        fillLight.light!.color = NSColor(white: 0.15, alpha: 1.0)
        fillLight.eulerAngles = SCNVector3(Float.pi / 4, -Float.pi / 3, 0)
        scene.rootNode.addChildNode(fillLight)

        // Carousel pivot (rotation target)
        scene.rootNode.addChildNode(carouselPivotNode)

        // Ring (torus)
        let torus = SCNTorus(ringRadius: carouselRadius, pipeRadius: 0.07)
        torus.firstMaterial = shadedMaterial(color: NSColor(white: 0.3, alpha: 1.0))
        let ringNode = SCNNode(geometry: torus)
        ringNode.name = "ring"
        carouselPivotNode.addChildNode(ringNode)

        // Inner hub
        let hub = SCNCylinder(radius: 1.0, height: 0.25)
        hub.firstMaterial = shadedMaterial(color: NSColor(white: 0.25, alpha: 1.0))
        let hubNode = SCNNode(geometry: hub)
        hubNode.name = "hub"
        hubNode.position = SCNVector3(0, 0.125, 0)
        carouselPivotNode.addChildNode(hubNode)

        // Spokes
        for i in stride(from: 0, to: slotCount, by: 25) {
            let angle = (2.0 * CGFloat.pi * CGFloat(i)) / CGFloat(slotCount)
            let spokeLen = carouselRadius - 1.0
            let spoke = SCNCylinder(radius: 0.02, height: spokeLen)
            spoke.firstMaterial = shadedMaterial(color: NSColor(white: 0.22, alpha: 1.0))
            let spokeNode = SCNNode(geometry: spoke)
            let midR = (1.0 + carouselRadius) / 2
            spokeNode.position = SCNVector3(
                Float(midR * cos(angle)),
                0,
                Float(midR * sin(angle))
            )
            spokeNode.eulerAngles = SCNVector3(0, -Float(angle) + Float.pi / 2, Float.pi / 2)
            carouselPivotNode.addChildNode(spokeNode)
        }

        setupDriveNode()
    }

    private func setupDriveNode() {
        // Drive box — dark grey, on its side (tall, thin, roughly square face)
        let driveBox = SCNBox(width: driveWidth, height: driveHeight, length: driveDepth, chamferRadius: 0.06)
        driveBox.firstMaterial = shadedMaterial(color: NSColor(white: 0.12, alpha: 1.0), edgeBrightness: 0.15)
        let driveBoxNode = SCNNode(geometry: driveBox)
        driveBoxNode.name = "drive_box"
        driveNode.addChildNode(driveBoxNode)

        driveNode.name = "drive"
        driveNode.position = SCNVector3(0, Float(driveHeight / 2), 0)
        scene.rootNode.addChildNode(driveNode)

        // Slot opening on the +X face (facing the ring where discs enter)
        let slotOpening = SCNBox(width: 0.01, height: discRadius * 2 * 0.85, length: 0.04, chamferRadius: 0)
        let slotMat = SCNMaterial()
        slotMat.diffuse.contents = NSColor(white: 0.03, alpha: 1.0)
        slotMat.lightingModel = .constant
        slotOpening.firstMaterial = slotMat
        let slotNode = SCNNode(geometry: slotOpening)
        slotNode.position = SCNVector3(Float(driveWidth / 2) + 0.005, 0, 0)
        driveNode.addChildNode(slotNode)

        // Label
        let label = makeLabel("DRIVE")
        label.position = SCNVector3(0, Float(driveHeight / 2) + 0.3, 0)
        driveNode.addChildNode(label)
    }

    // MARK: - Build Slots

    func buildSlots(slots: [Slot], driveStatus: DriveStatus, selectedSlotId: Int?) {
        for (_, node) in slotNodes { node.removeFromParentNode() }
        slotNodes.removeAll()
        discNodes.removeAll()

        for slot in slots {
            let slotIndex = slot.id - 1
            let angle = (2.0 * CGFloat.pi * CGFloat(slotIndex)) / CGFloat(slotCount)

            let groupNode = SCNNode()
            groupNode.name = "slot_\(slot.id)"

            let x = Float(carouselRadius * cos(angle))
            let z = Float(carouselRadius * sin(angle))
            groupNode.position = SCNVector3(x, 0, z)
            groupNode.eulerAngles = SCNVector3(0, -Float(angle) + Float.pi / 2, 0)

            // Slot divider
            let divider = SCNBox(width: 0.015, height: 0.2, length: 0.12, chamferRadius: 0)
            let dividerNode = SCNNode(geometry: divider)
            dividerNode.geometry?.firstMaterial = slotDividerMaterial(isEmpty: !slot.isFull && !slot.isInDrive, isSelected: slot.id == selectedSlotId)
            dividerNode.position = SCNVector3(0, 0.1, 0)
            groupNode.addChildNode(dividerNode)

            // Disc
            if slot.isFull && !slot.isInDrive {
                let discNode = makeDiscNode(discType: slot.discType)
                discNode.name = "disc_\(slot.id)"
                discNode.position = SCNVector3(0, Float(discRadius), 0)
                groupNode.addChildNode(discNode)
                discNodes[slot.id] = discNode
            }

            carouselPivotNode.addChildNode(groupNode)
            slotNodes[slot.id] = groupNode
        }

        updateDriveDisc(driveStatus: driveStatus)
        if let id = selectedSlotId { highlightSlot(id) }
    }

    // MARK: - State Updates

    func updateSlotStates(slots: [Slot], selectedSlotId: Int?) {
        for slot in slots {
            guard let groupNode = slotNodes[slot.id] else { continue }
            let isSelected = slot.id == selectedSlotId
            let hasFull = slot.isFull && !slot.isInDrive

            if let dividerNode = groupNode.childNodes.first(where: { $0.geometry is SCNBox }) {
                dividerNode.geometry?.firstMaterial = slotDividerMaterial(isEmpty: !slot.isFull && !slot.isInDrive, isSelected: isSelected)
            }

            if hasFull && discNodes[slot.id] == nil && !animatingSlotIds.contains(slot.id) {
                let discNode = makeDiscNode(discType: slot.discType)
                discNode.name = "disc_\(slot.id)"
                discNode.position = SCNVector3(0, Float(discRadius), 0)
                groupNode.addChildNode(discNode)
                discNodes[slot.id] = discNode
            } else if !hasFull, let existing = discNodes[slot.id], !animatingSlotIds.contains(slot.id) {
                existing.removeFromParentNode()
                discNodes.removeValue(forKey: slot.id)
            } else if hasFull, let existing = discNodes[slot.id] {
                updateDiscMaterial(node: existing, discType: slot.discType)
            }
        }
        highlightedSlotId = selectedSlotId
    }

    func updateDriveDisc(driveStatus: DriveStatus) {
        driveDiscNode?.removeFromParentNode()
        driveDiscNode = nil

        switch driveStatus {
        case .loaded(_, _), .loading(_):
            let disc = makeDiscNode(discType: .unscanned)
            disc.name = "drive_disc"
            disc.position = SCNVector3(0, 0, 0)
            disc.scale = SCNVector3(0.45, 0.45, 0.45)
            driveNode.addChildNode(disc)
            driveDiscNode = disc
            updateDriveTint(NSColor(red: 0.1, green: 0.22, blue: 0.1, alpha: 1.0))

        case .ejecting(_):
            updateDriveTint(NSColor(red: 0.28, green: 0.22, blue: 0.06, alpha: 1.0))

        default:
            updateDriveTint(NSColor(white: 0.12, alpha: 1.0))
        }
    }

    // MARK: - Selection & Hover

    func highlightSlot(_ slotId: Int?) {
        // Clear previous
        if let prevId = highlightedSlotId {
            if let prevGroup = slotNodes[prevId] {
                if let divider = prevGroup.childNodes.first(where: { $0.geometry is SCNBox }) {
                    divider.geometry?.firstMaterial = slotDividerMaterial(isEmpty: discNodes[prevId] == nil, isSelected: false)
                }
            }
            // Remove selected glow from previous disc
            if let prevDisc = discNodes[prevId] {
                setDiscEmission(prevDisc, color: NSColor.black)
                prevDisc.scale = SCNVector3(1, 1, 1)
            }
        }

        selectedLabelNode?.removeFromParentNode()
        selectedLabelNode = nil

        guard let slotId = slotId, let groupNode = slotNodes[slotId] else {
            highlightedSlotId = nil
            return
        }

        highlightedSlotId = slotId

        // Highlight divider
        if let divider = groupNode.childNodes.first(where: { $0.geometry is SCNBox }) {
            divider.geometry?.firstMaterial = slotDividerMaterial(isEmpty: discNodes[slotId] == nil, isSelected: true)
        }

        // Strong glow on selected disc
        if let discNode = discNodes[slotId] {
            setDiscEmission(discNode, color: NSColor(white: 0.4, alpha: 1.0))
            discNode.scale = SCNVector3(1.05, 1.05, 1.05)
        }

        // Floating label
        let label = makeLabel("Slot \(slotId)")
        label.position = SCNVector3(0, Float(discRadius * 2) + 0.5, 0)
        label.constraints = [SCNBillboardConstraint()]
        groupNode.addChildNode(label)
        selectedLabelNode = label
    }

    func hoverSlot(_ slotId: Int?) {
        // Unhover previous
        if let prevId = hoveredSlotId, prevId != highlightedSlotId {
            if let prevGroup = slotNodes[prevId] {
                if let divider = prevGroup.childNodes.first(where: { $0.geometry is SCNBox }) {
                    divider.geometry?.firstMaterial = slotDividerMaterial(isEmpty: discNodes[prevId] == nil, isSelected: false)
                }
            }
            if let prevDisc = discNodes[prevId] {
                setDiscEmission(prevDisc, color: NSColor.black)
            }
        }

        hoveredSlotId = slotId

        guard let slotId = slotId, slotId != highlightedSlotId, let groupNode = slotNodes[slotId] else { return }

        // Hover divider
        if let divider = groupNode.childNodes.first(where: { $0.geometry is SCNBox }) {
            divider.geometry?.firstMaterial = slotDividerMaterial(isEmpty: false, isSelected: false, hovered: true)
        }

        // Subtle glow on hovered disc
        if let discNode = discNodes[slotId] {
            setDiscEmission(discNode, color: NSColor(white: 0.2, alpha: 1.0))
        }
    }

    // MARK: - Rotation

    func rotateToSlot(_ slotId: Int, duration: TimeInterval = 1.2) {
        let slotIndex = slotId - 1
        // Rotate carousel so the target slot faces +X (aligned with drive slot opening)
        let targetAngle = -(2.0 * Double.pi * Double(slotIndex)) / Double(slotCount)

        let currentAngle = Double(carouselPivotNode.eulerAngles.y)
        let delta = normalizeAngle(targetAngle - currentAngle)
        let finalAngle = currentAngle + delta

        let action = SCNAction.rotateTo(x: 0, y: CGFloat(finalAngle), z: 0, duration: duration)
        action.timingMode = .easeInEaseOut
        carouselPivotNode.runAction(action, forKey: "rotation")
    }

    // MARK: - Disc Transfer Animations

    /// Load disc from slot — rolls inward into the center drive
    func animateLoadDisc(slotId: Int) {
        guard let discNode = discNodes[slotId] else { return }
        animatingSlotIds.insert(slotId)

        // Phase 1: Tip disc to roll on edge (rotate Y by π/2)
        let tip = SCNAction.rotateBy(x: 0, y: CGFloat.pi / 2, z: 0, duration: 0.3)
        tip.timingMode = .easeInEaseOut

        // Phase 2: Roll toward drive center
        let travel = carouselRadius
        let rollDistance = travel
        // Number of rotations = distance / circumference = distance / (2πr)
        let circumference = 2.0 * CGFloat.pi * discRadius
        let rotations = rollDistance / circumference
        let rollAngle = rotations * 2.0 * CGFloat.pi

        let slide = SCNAction.moveBy(x: -travel, y: 0.1, z: 0, duration: 1.0)
        slide.timingMode = .easeInEaseOut
        let roll = SCNAction.rotateBy(x: rollAngle, y: 0, z: 0, duration: 1.0)
        let shrink = SCNAction.scale(to: 0.45, duration: 1.0)
        shrink.timingMode = .easeInEaseOut
        let rollPhase = SCNAction.group([slide, roll, shrink])

        // Phase 3: Tip back and enter drive slot
        let tipBack = SCNAction.rotateBy(x: 0, y: -CGFloat.pi / 2, z: 0, duration: 0.3)
        tipBack.timingMode = .easeInEaseOut

        let fadeOut = SCNAction.fadeOut(duration: 0.15)
        let remove = SCNAction.removeFromParentNode()

        let sequence = SCNAction.sequence([
            SCNAction.wait(duration: 1.2),
            tip,
            rollPhase,
            tipBack,
            fadeOut,
            remove
        ])

        discNode.runAction(sequence) { [weak self] in
            self?.discNodes.removeValue(forKey: slotId)
            self?.animatingSlotIds.remove(slotId)
            DispatchQueue.main.async {
                self?.showDriveDisc()
            }
        }
    }

    /// Eject disc from drive — rolls outward back into a slot
    func animateEjectDisc(toSlot slotId: Int) {
        animatingSlotIds.insert(slotId)
        driveDiscNode?.runAction(SCNAction.sequence([
            SCNAction.fadeOut(duration: 0.3),
            SCNAction.removeFromParentNode()
        ]))
        driveDiscNode = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, let groupNode = self.slotNodes[slotId] else { return }

            let discNode = self.makeDiscNode(discType: .unscanned)
            discNode.name = "disc_\(slotId)"
            let startX = Float(-self.carouselRadius)
            discNode.position = SCNVector3(startX, Float(self.discRadius) + 0.1, 0)
            discNode.opacity = 0
            discNode.scale = SCNVector3(0.45, 0.45, 0.45)
            groupNode.addChildNode(discNode)

            let fadeIn = SCNAction.fadeIn(duration: 0.15)

            // Tip to roll
            let tip = SCNAction.rotateBy(x: 0, y: CGFloat.pi / 2, z: 0, duration: 0.25)
            tip.timingMode = .easeInEaseOut

            // Roll outward
            let travel = self.carouselRadius
            let circumference = 2.0 * CGFloat.pi * self.discRadius
            let rotations = travel / circumference
            let rollAngle = -(rotations * 2.0 * CGFloat.pi)

            let slide = SCNAction.moveBy(x: travel, y: -0.1, z: 0, duration: 1.0)
            slide.timingMode = .easeInEaseOut
            let roll = SCNAction.rotateBy(x: rollAngle, y: 0, z: 0, duration: 1.0)
            let grow = SCNAction.scale(to: 1.0, duration: 1.0)
            grow.timingMode = .easeInEaseOut
            let rollPhase = SCNAction.group([slide, roll, grow])

            // Tip back into slot orientation
            let tipBack = SCNAction.rotateBy(x: 0, y: -CGFloat.pi / 2, z: 0, duration: 0.25)
            tipBack.timingMode = .easeInEaseOut

            discNode.runAction(SCNAction.sequence([fadeIn, tip, rollPhase, tipBack])) { [weak self] in
                self?.animatingSlotIds.remove(slotId)
            }
            self.discNodes[slotId] = discNode
        }
    }

    /// Eject disc from chamber — rolls outward past the ring and vanishes in smoke
    func animateEjectFromChamber(slotId: Int) {
        guard let discNode = discNodes[slotId] else { return }
        animatingSlotIds.insert(slotId)

        // Tip to roll on edge
        let tip = SCNAction.rotateBy(x: 0, y: CGFloat.pi / 2, z: 0, duration: 0.25)
        tip.timingMode = .easeInEaseOut

        // Roll outward past the ring
        let rollOut = SCNAction.moveBy(x: 5.0, y: 0.5, z: 0, duration: 1.2)
        rollOut.timingMode = .easeIn
        let circumference = 2.0 * CGFloat.pi * discRadius
        let rotations = 5.0 / circumference
        let spin = SCNAction.rotateBy(x: -(rotations * 2.0 * CGFloat.pi), y: 0, z: 0, duration: 1.2)
        let rollPhase = SCNAction.group([rollOut, spin])

        let puff = SCNAction.run { [weak self] node in
            self?.addSmokePuff(at: node.presentation.worldPosition)
        }
        let fadeOut = SCNAction.fadeOut(duration: 0.25)
        let remove = SCNAction.removeFromParentNode()

        let sequence = SCNAction.sequence([
            SCNAction.wait(duration: 1.2),
            tip,
            rollPhase,
            puff,
            fadeOut,
            remove
        ])

        discNode.runAction(sequence) { [weak self] in
            self?.discNodes.removeValue(forKey: slotId)
            self?.animatingSlotIds.remove(slotId)
        }
    }

    // MARK: - Hit Testing

    func hitTestSlot(at point: CGPoint, in scnView: SCNView) -> Int? {
        let hitResults = scnView.hitTest(point, options: [
            .searchMode: NSNumber(value: SCNHitTestSearchMode.closest.rawValue),
            .boundingBoxOnly: NSNumber(value: true)
        ])

        for result in hitResults {
            var node: SCNNode? = result.node
            while let current = node {
                if let name = current.name {
                    if name.hasPrefix("slot_") || name.hasPrefix("disc_") {
                        let parts = name.split(separator: "_")
                        if parts.count == 2, let slotId = Int(parts[1]) {
                            return slotId
                        }
                    }
                }
                node = current.parent
            }
        }
        return nil
    }

    // MARK: - Particle Effects

    private func addSmokePuff(at position: SCNVector3) {
        let system = SCNParticleSystem()
        system.particleColor = NSColor(white: 0.7, alpha: 0.6)
        system.particleColorVariation = SCNVector4(0.1, 0.1, 0.1, 0.2)
        system.particleSize = 0.2
        system.particleSizeVariation = 0.12
        system.emissionDuration = 0.15
        system.birthRate = 200
        system.particleLifeSpan = 0.7
        system.particleLifeSpanVariation = 0.2
        system.spreadingAngle = 180
        system.particleVelocity = 1.0
        system.particleVelocityVariation = 0.5
        system.acceleration = SCNVector3(0, 1.5, 0)
        system.dampingFactor = 2.0
        system.blendMode = .additive
        system.loops = false
        system.isAffectedByGravity = false

        let opacityAnim = CAKeyframeAnimation()
        opacityAnim.values = [1.0, 0.5, 0.0]
        opacityAnim.keyTimes = [0, 0.4, 1.0]
        opacityAnim.duration = 1.0
        system.propertyControllers = [
            .opacity: SCNParticlePropertyController(animation: opacityAnim)
        ]

        let sizeAnim = CAKeyframeAnimation()
        sizeAnim.values = [0.1, 0.35, 0.5]
        sizeAnim.keyTimes = [0, 0.3, 1.0]
        sizeAnim.duration = 1.0
        system.propertyControllers?[.size] = SCNParticlePropertyController(animation: sizeAnim)

        let emitterNode = SCNNode()
        emitterNode.position = position
        emitterNode.addParticleSystem(system)
        scene.rootNode.addChildNode(emitterNode)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            emitterNode.removeFromParentNode()
        }
    }

    // MARK: - Helpers

    private func showDriveDisc() {
        driveDiscNode?.removeFromParentNode()
        let disc = makeDiscNode(discType: .unscanned)
        disc.name = "drive_disc"
        disc.position = SCNVector3(0, 0, 0)
        disc.scale = SCNVector3(0.45, 0.45, 0.45)
        disc.opacity = 0
        driveNode.addChildNode(disc)
        disc.runAction(SCNAction.fadeIn(duration: 0.3))
        driveDiscNode = disc
    }

    private func makeDiscNode(discType: SlotDiscType) -> SCNNode {
        let tube = SCNTube(innerRadius: discHoleRadius, outerRadius: discRadius, height: discThickness)
        let mat = discMaterial(for: discType)
        tube.materials = [mat, mat, mat, mat]
        let node = SCNNode(geometry: tube)
        node.eulerAngles = SCNVector3(0, 0, Float.pi / 2)
        return node
    }

    private func updateDiscMaterial(node: SCNNode, discType: SlotDiscType) {
        let mat = discMaterial(for: discType)
        if let tube = node.geometry as? SCNTube {
            tube.materials = [mat, mat, mat, mat]
        }
    }

    private func setDiscEmission(_ node: SCNNode, color: NSColor) {
        if let tube = node.geometry as? SCNTube {
            for mat in tube.materials {
                mat.emission.contents = color
            }
        }
    }

    private func makeLabel(_ text: String) -> SCNNode {
        let textGeo = SCNText(string: text, extrusionDepth: 0)
        textGeo.font = NSFont.systemFont(ofSize: 0.12, weight: .medium)
        textGeo.flatness = 0.1
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor.white
        mat.lightingModel = .constant
        textGeo.firstMaterial = mat

        let textNode = SCNNode(geometry: textGeo)
        let (min, max) = textNode.boundingBox
        let dx = (max.x - min.x) / 2
        textNode.pivot = SCNMatrix4MakeTranslation(dx, 0, 0)
        return textNode
    }

    private func updateDriveTint(_ color: NSColor) {
        guard let boxNode = driveNode.childNodes.first(where: { $0.name == "drive_box" }) else { return }
        boxNode.geometry?.firstMaterial = shadedMaterial(color: color, edgeBrightness: 0.15)
    }

    // MARK: - Materials

    private func shadedMaterial(color: NSColor, edgeBrightness: Float = 0.25, shininess: CGFloat = 0.3) -> SCNMaterial {
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.specular.contents = NSColor(white: 0.2, alpha: 1.0)
        mat.shininess = shininess
        mat.lightingModel = .phong
        mat.isDoubleSided = true
        mat.shaderModifiers = [
            .fragment: """
            float fresnel = pow(1.0 - abs(dot(_surface.normal, normalize(_surface.view))), 3.0);
            _output.color.rgb += vec3(\(edgeBrightness)) * fresnel;
            """
        ]
        return mat
    }

    private func discMaterial(for discType: SlotDiscType) -> SCNMaterial {
        let color = discFillColor(for: discType)
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.specular.contents = NSColor(white: 0.5, alpha: 1.0)
        mat.shininess = 0.6
        mat.lightingModel = .phong
        mat.isDoubleSided = true
        mat.shaderModifiers = [
            .fragment: """
            float fresnel = pow(1.0 - abs(dot(_surface.normal, normalize(_surface.view))), 2.5);
            _output.color.rgb += vec3(0.35) * fresnel;
            """
        ]
        return mat
    }

    private func slotDividerMaterial(isEmpty: Bool, isSelected: Bool, hovered: Bool = false) -> SCNMaterial {
        let mat = SCNMaterial()
        mat.lightingModel = .phong
        mat.isDoubleSided = true
        if isSelected {
            mat.diffuse.contents = NSColor.white
            mat.emission.contents = NSColor(white: 0.3, alpha: 1.0)
        } else if hovered {
            mat.diffuse.contents = NSColor(white: 0.55, alpha: 1.0)
        } else if isEmpty {
            mat.diffuse.contents = NSColor(white: 0.2, alpha: 1.0)
        } else {
            mat.diffuse.contents = NSColor(white: 0.35, alpha: 1.0)
        }
        return mat
    }

    private func discFillColor(for discType: SlotDiscType) -> NSColor {
        switch discType {
        case .audioCDDA:   return NSColor(red: 0.5, green: 0.2, blue: 0.6, alpha: 1.0)
        case .dvd:         return NSColor(red: 0.2, green: 0.5, blue: 0.25, alpha: 1.0)
        case .dataCD:      return NSColor(red: 0.2, green: 0.35, blue: 0.6, alpha: 1.0)
        case .mixedModeCD: return NSColor(red: 0.6, green: 0.4, blue: 0.15, alpha: 1.0)
        case .unknown:     return NSColor(white: 0.35, alpha: 1.0)
        case .unscanned:   return NSColor(white: 0.4, alpha: 1.0)
        }
    }

    private func normalizeAngle(_ angle: Double) -> Double {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a > .pi { a -= 2 * .pi }
        if a < -.pi { a += 2 * .pi }
        return a
    }
}
