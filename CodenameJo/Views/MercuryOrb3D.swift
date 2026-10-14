import SceneKit
import SwiftUI
import UIKit
import simd

// The 3D mercury bead: a deforming chrome blob on the ground, tinted by session state.
// No halo and a fixed camera by design: listening brightens the floor glow instead.

/// The bead's read of the session. `droplet` is a dispatch satellite: it rests like
/// `ready` but keeps the session's colour.
enum OrbMood: Equatable {
    case ready, connecting, listening, thinking, responding, muted, error, droplet
}

extension OrbMood {
    /// The design's own hexes, not `Theme`: the bead reflects a fixed room, so its tint does not
    /// adapt. Dark variants are the next-lighter hue in each family; violet goes to `muted`, not `ready`.
    var tint: Color {
        switch self {
        case .ready: return Self.tint(light: 0x9AA0AC, dark: 0x9AA0AC)
        case .droplet: return Self.tint(light: 0x714CB6, dark: 0x9A6BF0)
        // One gold across all three, exactly as the design's light palette has it.
        case .connecting, .listening, .thinking: return Self.tint(light: 0xB08A2E, dark: 0xF5C045)
        case .responding: return Self.tint(light: 0x4DB37A, dark: 0x63C88F)
        case .muted: return Self.tint(light: 0x714CB6, dark: 0x9A6BF0)
        case .error: return Self.tint(light: 0xE64752, dark: 0xF26370)
        }
    }

    private static func tint(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) })
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Scene

/// Owns the SceneKit graph and the per-frame simulation. Not `@MainActor`: the delegate
/// runs on SceneKit's render thread and touches only scene state and values under `lock`.
final class MercuryOrbScene: NSObject, SCNSceneRendererDelegate {

    // Geometry constants, verbatim from the design's `makeBlob`.
    private static let radius: Float = 0.074
    private static let flatten: Float = 0.035
    private static let bulge: Float = 0.018
    private static let spread: Float = 0.34
    /// Stage size relative to the bead: how far the view overdraws its layout frame.
    /// It must fit the 2.4R ground glow; the stage renders `stageScale²` times the orb's pixels.
    static let stageScale: CGFloat = 1.9
    /// The design's reduced-motion clock: one still frame at t = 2.0.
    private static let stillTime: Float = 2.0

    let scene = SCNScene()

    /// Floating mode, for the welcome hero: no ground, full ripple at a 0.55 clock, a spin,
    /// a lean, a drift and swinging lights. The camera stays fixed.
    private let floating: Bool

    private let quicksilver = SCNMaterial()
    private let lightsRig = SCNNode()
    private let bobbleNode = SCNNode()
    private let beadNode: SCNNode
    private let glowNode: SCNNode
    private let shadowNode: SCNNode
    private let arcHolder = SCNNode()
    private let arcMaterial = SCNMaterial()
    private let dotsHolder = SCNNode()
    private var dotNodes: [SCNNode] = []

    // Targets, written by the main thread and read by the render thread.
    private let lock = NSLock()
    private var targetMood: OrbMood = .ready
    private var targetTint = simd_float3(0.443, 0.298, 0.714)
    private var knocksRequested = 0
    private var stillFrame = false
    private var darkRoom = false
    /// A specific instant to draw instead of running the clock. `nil` while the
    /// scene is live; set by `renderStill`, which is how the car gets frames.
    private var frozenTime: Float?

    // Live simulation state, render thread only.
    private var simT: Float = MercuryOrbScene.stillTime
    private var elapsedReal: Float = 0
    private var lastTime: TimeInterval?
    private var liveAmp: Float = 0.28
    private var liveSpeed: Float = 1.0
    private var liveWash: Float = 0.0
    private var liveTint = simd_float3(0.443, 0.298, 0.714)
    private var knocksApplied = 0
    /// Whether the first `setTargets` has been seen — see the note there.
    private var knocksSeeded = false
    private var lastJolt: Float = 0
    // The bobble: an under-damped angular spring about the contact point.
    private var springX: Float = 0
    private var springZ: Float = 0
    private var springVX: Float = 0
    private var springVZ: Float = 0
    private static let springK: Float = {
        let w = 2 * Float.pi / 0.55
        return w * w
    }()
    private static let springDamping: Float = 2 * 0.42 * (2 * Float.pi / 0.55)

    /// Per-mood ripple amplitude, clock rate and tint wash. `.ready` alone has zero wash.
    private static func params(for mood: OrbMood) -> (amp: Float, speed: Float, wash: Float) {
        switch mood {
        case .ready: return (0.28, 1.0, 0.0)
        case .connecting: return (0.34, 1.35, 0.3)
        case .listening: return (0.32, 1.0, 0.3)
        case .thinking: return (0.30, 0.85, 0.3)
        case .responding: return (0.30, 1.0, 0.3)
        case .muted: return (0.10, 0.55, 0.3)
        case .error: return (0.44, 1.6, 0.3)
        // Plain chrome: no wash, and `renderFrame` gives it no coloured floor pool.
        case .droplet: return (0.28, 1.0, 0.0)
        }
    }

    init(floating: Bool = false) {
        self.floating = floating
        let r = CGFloat(Self.radius)

        // A high-density sphere displaced every frame by the shader modifier. The floating
        // hero takes the stronger squash and no floor; the sessile orb flattens its base.
        let sphere = SCNSphere(radius: r)
        sphere.segmentCount = 120
        quicksilver.lightingModel = .physicallyBased
        quicksilver.diffuse.contents = UIColor.white
        quicksilver.metalness.contents = 1.0
        // The icon's polish.
        quicksilver.roughness.contents = 0.028
        sphere.materials = [quicksilver]
        sphere.shaderModifiers = [.geometry: floating
            ? Self.blobShader(flatten: 0, bulge: 0, sxAmp: 0.035, syAmp: 0.04, syAmp2: 0.015)
            : Self.blobShader(flatten: Self.flatten, bulge: Self.bulge,
                              sxAmp: 0.012, syAmp: 0.014, syAmp2: 0.005)]
        beadNode = SCNNode(geometry: sphere)

        // A soft contact shadow and the tinted glow disc, sized so their projection stays inside
        // the orb's layout frame; the welcome slide clips 24 pt below the bead.
        shadowNode = Self.spriteNode(
            plane: SCNPlane(width: r * 2.2, height: r * 2.2),
            texture: Self.radialTexture, additive: false, renderingOrder: -10)
        shadowNode.geometry?.firstMaterial?.multiply.contents = UIColor.black
        shadowNode.eulerAngles.x = -.pi / 2
        shadowNode.position.y = 0.0004
        shadowNode.opacity = 0.32

        glowNode = Self.spriteNode(
            plane: SCNPlane(width: r * 2.4, height: r * 2.4),
            texture: Self.radialTexture, additive: false, renderingOrder: -9)
        glowNode.eulerAngles.x = -.pi / 2
        glowNode.position.y = 0.0006
        // Starts invisible: the idle bead is chrome over a plain shadow, and the
        // glow only comes up with a call state's wash (see `renderFrame`).
        glowNode.opacity = 0

        super.init()

        bobbleNode.addChildNode(beadNode)
        scene.rootNode.addChildNode(bobbleNode)
        // A floating bead touches nothing, so it grounds on nothing.
        shadowNode.isHidden = floating
        glowNode.isHidden = floating
        scene.rootNode.addChildNode(shadowNode)
        scene.rootNode.addChildNode(glowNode)

        // Thinking arc: a bright partial torus riding a tilted orbit at the
        // app's own 0.42 laps/s sweep rate.
        arcMaterial.lightingModel = .constant
        arcMaterial.diffuse.contents = UIColor.white
        arcMaterial.writesToDepthBuffer = false
        arcMaterial.transparency = 0.9
        let arc = SCNNode(geometry: Self.arcGeometry(
            major: Self.radius * 1.06, tube: Self.radius * 0.018,
            arc: Float.pi * 0.44, material: arcMaterial))
        arcHolder.addChildNode(arc)
        arcHolder.eulerAngles.x = 0.5
        arcHolder.isHidden = true
        scene.rootNode.addChildNode(arcHolder)

        // Thinking dots: three white dots rising and falling out of phase,
        // drawn over the metal (depth test off) like the 2D overlay was.
        dotsHolder.constraints = [SCNBillboardConstraint()]
        for i in 0..<3 {
            let dotSphere = SCNSphere(radius: r * 0.108)
            dotSphere.segmentCount = 20
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = UIColor.white
            m.readsFromDepthBuffer = false
            m.writesToDepthBuffer = false
            dotSphere.materials = [m]
            let dot = SCNNode(geometry: dotSphere)
            dot.renderingOrder = 10
            dot.position = SCNVector3(Float(i - 1) * Self.radius * 0.378, 0, Self.radius * 1.05)
            dotsHolder.addChildNode(dot)
            dotNodes.append(dot)
        }
        dotsHolder.isHidden = true
        scene.rootNode.addChildNode(dotsHolder)

        // The horizon gradient lights the chrome; there is nothing rectangular to reflect.
        scene.lightingEnvironment.contents = Self.horizonTexture
        scene.lightingEnvironment.intensity = 1.25
        scene.background.contents = UIColor.clear

        // Two dimmed directionals, each one small highlight on a mirror ball. Neither casts
        // shadows; the grounding is the shadow sprite.
        let key = SCNLight()
        key.type = .directional
        key.intensity = 660
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.simdPosition = simd_float3(4, 7, 5)
        keyNode.simdLook(at: simd_float3(0, 0, 0), up: simd_float3(0, 1, 0),
                         localFront: simd_float3(0, 0, -1))
        lightsRig.addChildNode(keyNode)
        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 150
        fill.color = UIColor(red: 1.0, green: 0.957, blue: 0.902, alpha: 1)   // #fff4e6
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.simdPosition = simd_float3(-5, 3, -4)
        fillNode.simdLook(at: simd_float3(0, 0, 0), up: simd_float3(0, 1, 0),
                          localFront: simd_float3(0, 0, -1))
        lightsRig.addChildNode(fillNode)
        // One rig so floating mode can swing both lights: the gradient room is horizontally
        // uniform, so the lights are what can visibly move.
        scene.rootNode.addChildNode(lightsRig)

        // Computed once and never moved. Sessile: the bead's 2R spans 1/stageScale of the view.
        // Floating: fov 26 at (0, 0.34, 5.9) radii, so the bead spans ~74% of the view.
        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = 10
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        if floating {
            camera.fieldOfView = 26
            cameraNode.simdPosition = simd_float3(0, Self.radius * 0.34, Self.radius * 5.9)
            cameraNode.simdLook(at: simd_float3(0, 0, 0), up: simd_float3(0, 1, 0),
                                localFront: simd_float3(0, 0, -1))
        } else {
            camera.fieldOfView = 45
            let target = simd_float3(0, Self.radius * 0.97, 0)
            let dir = simd_normalize(simd_float3(1, 0.55, 1.25))
            let dist = Float(Self.stageScale) * Self.radius / tan(Float(22.5 * Double.pi / 180))
            cameraNode.simdPosition = target + dir * dist
            cameraNode.simdLook(at: target, up: simd_float3(0, 1, 0), localFront: simd_float3(0, 0, -1))
        }
        scene.rootNode.addChildNode(cameraNode)

        renderFrame(dt: 0)
    }

    /// New targets from SwiftUI. Each `knock` increment is one bobble impulse; `darkRoom`
    /// grounds the bead with a sheen instead of a shadow.
    func setTargets(mood: OrbMood, tint: simd_float3, knock: Int, stillFrame: Bool, darkRoom: Bool) {
        lock.lock()
        targetMood = mood
        targetTint = tint
        // The first count seen is the baseline, not a backlog: `knock` is the parent's tapCount,
        // which keeps counting while this scene is rebuilt, so replaying it would lurch to the clamp.
        if !knocksSeeded {
            knocksSeeded = true
            knocksApplied = knock
        }
        knocksRequested = knock
        self.stillFrame = stillFrame
        self.darkRoom = darkRoom
        lock.unlock()
    }

    /// Draw one instant with eased params snapped to the mood, so CarPlay can render frames.
    /// The spring is zeroed (a still cannot carry a knock); `darkRoom` keeps the bead grounded.
    func renderStill(mood: OrbMood, tint: simd_float3, at t: TimeInterval, darkRoom: Bool) {
        lock.lock()
        targetMood = mood
        targetTint = tint
        stillFrame = true
        frozenTime = Float(t)
        self.darkRoom = darkRoom
        lock.unlock()
        renderFrame(dt: 0)
    }

    /// Draw one frame from the targets already set, without starting a clock. Reduce Motion
    /// stops the renderer, so without this a still orb never shows a state change.
    func drawStillFrame() {
        renderFrame(dt: 0)
    }

    // MARK: Per-frame simulation (render thread)

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = Float(min(0.05, lastTime.map { time - $0 } ?? 0.016))
        lastTime = time
        renderFrame(dt: dt)
    }

    /// Reveals the view once a real frame exists; `makeUIView` hands it over at alpha 0.
    func renderer(_ renderer: SCNSceneRenderer, didRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard let view = renderer as? SCNView else { return }
        DispatchQueue.main.async {
            if view.alpha == 0 { view.alpha = 1 }
        }
    }

    private func renderFrame(dt: Float) {
        lock.lock()
        let mood = targetMood
        let tint = targetTint
        let knocks = knocksRequested
        let still = stillFrame
        let dark = darkRoom
        lock.unlock()

        // Floating hero: the design's fixed pose — full-amplitude ripple, a
        // 0.55 clock, and no tint ever. States never reach it.
        let (baseAmp, speed, wash) = floating ? (1.0, 0.55, 0.0) : Self.params(for: mood)

        // Ease the live params toward the state's targets, so a state switch
        // reads as the same liquid changing mood rather than a cut.
        let ease = still ? 1 : 1 - exp(-dt * 6)
        liveSpeed += (speed - liveSpeed) * ease
        var ampTarget = baseAmp
        if mood == .responding {
            // The ripple chatters like speech.
            ampTarget = baseAmp * (0.75 + 0.55 * abs(sin(simT * 5.2)) * (0.6 + 0.4 * sin(simT * 1.7)))
        }
        liveAmp += (ampTarget - liveAmp) * ease
        liveWash += (wash - liveWash) * ease
        liveTint += (tint - liveTint) * ease

        if still {
            simT = frozenTime ?? Self.stillTime
            springX = 0; springZ = 0; springVX = 0; springVZ = 0
            knocksApplied = knocks
        } else {
            simT += dt * liveSpeed

            // A tap knocks the bead; error jolts it through the same spring.
            while knocksApplied < knocks {
                knocksApplied += 1
                springVZ += 1.8 * (knocksApplied % 2 == 0 ? 1 : -1)
                springVX += 0.6
            }
            if mood == .error, simT - lastJolt > 2.2 {
                lastJolt = simT
                springVZ += 1.1 * (sin(simT * 3.1) > 0 ? 1 : -1)
            }

            // Semi-implicit Euler, clamped so the bead can never lie down.
            springVX += (-Self.springK * springX - Self.springDamping * springVX) * dt
            springVZ += (-Self.springK * springZ - Self.springDamping * springVZ) * dt
            springX = max(-0.5, min(0.5, springX + springVX * dt))
            springZ = max(-0.5, min(0.5, springZ + springVZ * dt))
        }

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0

        // The GPU does the liquid; it only needs the clock and the amplitude.
        quicksilver.setValue(NSNumber(value: simT), forKey: "uSimT")
        quicksilver.setValue(NSNumber(value: liveAmp), forKey: "uAmp")

        // Rest the bead on the ground: the shader's squash minus the flattened base, analytic
        // because the deformation vanishes at the bottom pole.
        let squash = sin(simT * 1.15)
        let sy = 1 - 0.014 * squash + 0.005 * sin(simT * 1.9 + 0.8)
        let lean = (0.5 * Float.pi / 180) * sin(simT * 0.5 + 0.7)
        let restY = Self.radius * sy - Self.radius * Self.flatten
        if floating {
            // The hero float: a slow turntable on real time, a lean, a small drift, and the lights
            // swinging so the highlight slides across the metal.
            if !still { elapsedReal += dt }
            beadNode.eulerAngles.y = elapsedReal * 0.05
            beadNode.eulerAngles.z = (1.4 * Float.pi / 180) * sin(simT * 0.5 + 0.7)
            beadNode.position = SCNVector3(
                Self.radius * 0.045 * sin(simT * 0.43),
                Self.radius * 0.030 * sin(simT * 0.77 + 2.1),
                0)
            lightsRig.eulerAngles = SCNVector3(
                0.05 * sin(simT * 1.1 + 1.3),
                0.09 * sin(simT * 0.7),
                0)
        } else {
            beadNode.eulerAngles.z = lean
            beadNode.position.y = restY * cos(lean)
        }

        bobbleNode.eulerAngles.x = springX
        bobbleNode.eulerAngles.z = springZ
        // Connecting: a gentle swell, the "coming up" breath.
        let swell: Float = mood == .connecting && !still ? 1 + 0.02 * sin(simT * 4.2) : 1
        bobbleNode.scale = SCNVector3(swell, swell, swell)

        // Tint wash: chrome picks up the state colour, and nothing at all when idle.
        let washed = simd_float3(1, 1, 1) + (liveTint - simd_float3(1, 1, 1)) * liveWash
        quicksilver.diffuse.contents = Self.color(washed)
        let indicator = Self.color(liveTint)

        // The glow disc rides the wash, except on a dark screen, where a neutral sheen holds the
        // pool because a black shadow grounds nothing.
        let washFraction = liveWash / 0.3
        // A droplet gets no coloured pool: at 44 pt it reads as a second light source.
        let poolFraction = mood == .droplet ? 0 : washFraction
        // A droplet has nothing on its floor, not even the contact shadow.
        shadowNode.isHidden = floating || mood == .droplet
        let neutral = simd_float3(0.604, 0.627, 0.675)   // #9aa0ac
        let glowColor = neutral + (liveTint - neutral) * poolFraction
        glowNode.geometry?.firstMaterial?.multiply.contents = Self.color(glowColor)
        // The floor pool never changes size; an open mic only brightens it.
        let listening = mood == .listening
        let washGlow = CGFloat(poolFraction) * (listening ? 0.44 : 0.30)
        // The dark-room minimum keeps an idle bead grounded on black; a droplet has no floor.
        glowNode.opacity = (dark && mood != .droplet) ? max(washGlow, 0.24) : washGlow

        // Thinking: the rim-sweep arc orbits, the dots rise and fall.
        let thinking = mood == .thinking
        arcHolder.isHidden = !thinking
        dotsHolder.isHidden = !thinking
        if thinking {
            arcHolder.position.y = restY
            arcHolder.eulerAngles.y = -simT * 0.42 * 2 * .pi
            arcMaterial.diffuse.contents = indicator
            dotsHolder.position.y = restY
            for (i, dot) in dotNodes.enumerated() {
                let ph = simT * 3.4 - Float(i) * 0.55
                dot.position.y = Self.radius * 0.122 * sin(ph)
                dot.opacity = CGFloat(0.5 + 0.5 * ((sin(ph) + 1) / 2))
            }
        }

        SCNTransaction.commit()
    }

    // MARK: Pieces

    private static func color(_ rgb: simd_float3) -> UIColor {
        UIColor(red: CGFloat(max(0, min(1, rgb.x))),
                green: CGFloat(max(0, min(1, rgb.y))),
                blue: CGFloat(max(0, min(1, rgb.z))),
                alpha: 1)
    }

    private static func spriteNode(
        plane: SCNPlane, texture: UIImage, additive: Bool, renderingOrder: Int
    ) -> SCNNode {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = texture
        // Clamp: SceneKit wraps textures by default, which draws a hard bright ring at the
        // plane's edge where the glow should have faded out.
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        if additive { m.blendMode = .add }
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.renderingOrder = renderingOrder
        node.castsShadow = false
        return node
    }

    /// A partial torus in the XZ plane — SceneKit's own `SCNTorus` is a full
    /// ring, and the design's sweep is an arc.
    private static func arcGeometry(
        major: Float, tube: Float, arc: Float, material: SCNMaterial
    ) -> SCNGeometry {
        let segU = 48, segV = 10
        var positions: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var indices: [Int32] = []
        for u in 0...segU {
            let a = arc * Float(u) / Float(segU)
            let center = simd_float3(cos(a) * major, 0, sin(a) * major)
            let outward = simd_float3(cos(a), 0, sin(a))
            for v in 0...segV {
                let b = 2 * Float.pi * Float(v) / Float(segV)
                let n = outward * cos(b) + simd_float3(0, sin(b), 0)
                let p = center + n * tube
                positions.append(SCNVector3(p))
                normals.append(SCNVector3(n))
            }
        }
        let stride = Int32(segV + 1)
        for u in 0..<segU {
            for v in 0..<segV {
                let a = Int32(u) * stride + Int32(v)
                indices.append(contentsOf: [a, a + stride, a + 1, a + 1, a + stride, a + stride + 1])
            }
        }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: positions), SCNGeometrySource(normals: normals)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        geometry.materials = [material]
        return geometry
    }

    /// The soft radial gradient behind every sprite: glow and shadow.
    private static let radialTexture: UIImage = {
        let size = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [
                UIColor(white: 1, alpha: 1).cgColor,
                UIColor(white: 1, alpha: 0.28).cgColor,
                UIColor(white: 1, alpha: 0).cgColor,
            ] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors, locations: [0, 0.55, 1]) else { return }
            ctx.cgContext.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: 128, y: 128), startRadius: 0,
                endCenter: CGPoint(x: 128, y: 128), endRadius: 128,
                options: [])
        }
    }()

    /// The horizon room as an equirectangular map: bright sky, a hard dark band, bounce light.
    private static let horizonTexture: UIImage = {
        let size = CGSize(width: 512, height: 256)
        let stops: [(CGFloat, UIColor)] = [
            (0.00, UIColor(red: 1, green: 1, blue: 1, alpha: 1)),
            (0.30, UIColor(red: 0.831, green: 0.843, blue: 0.871, alpha: 1)),   // #d4d7de
            (0.48, UIColor(red: 0.471, green: 0.482, blue: 0.518, alpha: 1)),   // #787b84
            (0.56, UIColor(red: 0.102, green: 0.106, blue: 0.125, alpha: 1)),   // #1a1b20
            (0.64, UIColor(red: 0.047, green: 0.051, blue: 0.067, alpha: 1)),   // #0c0d11
            (0.72, UIColor(red: 0.667, green: 0.690, blue: 0.733, alpha: 1)),   // #aab0bb
            (0.86, UIColor(red: 0.235, green: 0.243, blue: 0.271, alpha: 1)),   // #3c3e45
            (1.00, UIColor(red: 0.082, green: 0.086, blue: 0.102, alpha: 1)),   // #15161a
        ]
        return UIGraphicsImageRenderer(size: size).image { ctx in
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: stops.map { $0.1.cgColor } as CFArray,
                locations: stops.map { $0.0 }) else { return }
            ctx.cgContext.drawLinearGradient(
                gradient,
                start: .zero, end: CGPoint(x: 0, y: size.height),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
    }()

    /// The blob on the GPU: radius modulated by three belt-weighted travelling harmonics, with
    /// squash and an optional flattened base. Normals blend to the sphere normal at the poles.
    private static func blobShader(
        flatten: Float, bulge: Float, sxAmp: Float, syAmp: Float, syAmp2: Float
    ) -> String { """
    #pragma arguments
    float uSimT;
    float uAmp;

    #pragma declaration
    float3 mercuryPoint(float theta, float polar, float t, float amp) {
        const float R = \(radius);
        float sp = sin(polar);
        float cp = cos(polar);
        float belt = pow(max(sp, 0.0), 1.2);
        float a1 = 0.051 * amp;
        float a2 = 0.032 * amp;
        float a3 = 0.017 * amp;
        float p1 = t * 0.9;
        float p2 = -t * 1.4 + 1.0;
        float p3 = t * 2.3 + 2.4;
        float A = a1 * sin(2.0 * theta + p1)
                + a2 * sin(3.0 * theta + p2)
                + a3 * sin(5.0 * theta + p3);
        float B = 0.024 * amp * sin(theta + t * 0.35);
        float C = sin(2.0 * polar + t * 0.7 + 0.6);
        float r = R * (1.0 + belt * A + sp * C * B);
        float squash = sin(t * 1.15);
        float sx = 1.0 + \(sxAmp) * squash;
        float sy = 1.0 - \(syAmp) * squash + \(syAmp2) * sin(t * 1.9 + 0.8);
        float y = r * cp * sy;
        float floorY = -R * sy;
        float u = (y - floorY) / (R * \(spread));
        float g = exp(-u * u);
        y += R * \(flatten) * g;
        float b = (1.0 + \(bulge) * g) * sx;
        float rs = r * sp;
        return float3(rs * cos(theta) * b, y, rs * sin(theta) * b);
    }

    #pragma body
    float3 mp = _geometry.position.xyz;
    float3 dir = mp / max(length(mp), 1e-6);
    float polar = acos(clamp(dir.y, -1.0, 1.0));
    float theta = atan2(dir.z, dir.x);
    float3 P = mercuryPoint(theta, polar, uSimT, uAmp);
    float e = 0.012;
    float pl = clamp(polar, e, 3.1415926 - e);
    float3 dT = mercuryPoint(theta + e, pl, uSimT, uAmp)
              - mercuryPoint(theta - e, pl, uSimT, uAmp);
    float3 dP = mercuryPoint(theta, pl + e, uSimT, uAmp)
              - mercuryPoint(theta, pl - e, uSimT, uAmp);
    float3 n = normalize(cross(dT, dP));
    float w = smoothstep(0.0, 0.18, sin(polar));
    n = normalize(mix(dir, n, w));
    _geometry.position.xyz = P;
    _geometry.normal = n;
    """ }
}

// MARK: - SwiftUI wrapper

/// The bead as a SwiftUI view: callers size it `diameter × stageScale` and the bead spans
/// `diameter` points. Never intercepts touches; `knock` carries the tap in.
struct MercuryOrb3D: UIViewRepresentable {
    var mood: OrbMood
    var tint: Color
    var knock: Int
    /// The welcome hero's pose: floating, spinning, full ripple. See the note
    /// on `MercuryOrbScene.floating`.
    var floating: Bool = false

    final class Coordinator {
        let orbScene: MercuryOrbScene
        init(floating: Bool) { orbScene = MercuryOrbScene(floating: floating) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(floating: floating) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        // Configure before the scene is attached: an SCNView starts opaque and white,
        // and the renderer takes its first frame from whatever state it was given.
        view.backgroundColor = .clear
        // `isOpaque` as well as a clear background: an opaque view composites onto black and
        // its `snapshot()` drops the alpha, leaving a black square around the bead.
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 30
        // Hidden until SceneKit has drawn a frame; the first one compiles the shaders
        // and prefilters the IBL, and what it presents meanwhile flashes white.
        view.alpha = 0
        view.scene = context.coordinator.orbScene.scene
        view.delegate = context.coordinator.orbScene
        view.rendersContinuously = true
        view.isPlaying = true
        apply(to: view, context: context)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        apply(to: view, context: context)
    }

    private func apply(to view: SCNView, context: Context) {
        let resolved = UIColor(tint).resolvedColor(
            with: UITraitCollection(userInterfaceStyle:
                context.environment.colorScheme == .dark ? .dark : .light))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let still = context.environment.accessibilityReduceMotion
        context.coordinator.orbScene.setTargets(
            mood: mood,
            tint: simd_float3(Float(red), Float(green), Float(blue)),
            knock: knock,
            stillFrame: still,
            darkRoom: context.environment.colorScheme == .dark)
        // A still frame needs no clock: render on demand instead of at 30fps.
        view.rendersContinuously = !still
        view.isPlaying = !still
        // But it still needs one draw here, or a Reduce Motion orb never shows a later mood.
        if still {
            context.coordinator.orbScene.drawStillFrame()
            view.setNeedsDisplay()
        }
    }
}

// MARK: - Snapshots

/// The bead at one named instant, as a `UIImage`, for CarPlay's animated frames.
/// Snapshots SceneKit directly: `ImageRenderer` renders a `UIViewRepresentable` empty.
@MainActor
enum MercuryOrbSnapshot {
    /// One reusable rig. Building a scene costs a prefiltered environment map and
    /// a shader compile, and the car asks for twenty frames per state.
    private static var rig: (view: SCNView, scene: MercuryOrbScene, side: CGFloat)?

    static func image(
        mood: OrbMood,
        tint: Color,
        at t: TimeInterval,
        side: CGFloat,
        style: UIUserInterfaceStyle
    ) -> UIImage? {
        let current: (view: SCNView, scene: MercuryOrbScene, side: CGFloat)
        if let existing = rig, existing.side == side {
            current = existing
        } else {
            let scene = MercuryOrbScene()
            let view = SCNView(frame: CGRect(x: 0, y: 0, width: side, height: side))
            view.scene = scene.scene
            view.backgroundColor = .clear
            // Non-opaque, or `snapshot()` discards the alpha and the car shows a black square.
            view.isOpaque = false
            view.antialiasingMode = .multisampling4X
            // No delegate and no clock: every frame is asked for by name.
            view.isPlaying = false
            view.rendersContinuously = false
            current = (view, scene, side)
            rig = current
        }

        let resolved = UIColor(tint).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        current.scene.renderStill(
            mood: mood,
            tint: simd_float3(Float(red), Float(green), Float(blue)),
            at: t,
            // The car's appearance, not the phone's, sets both tint and grounding.
            darkRoom: style == .dark
        )
        return current.view.snapshot()
    }
}
