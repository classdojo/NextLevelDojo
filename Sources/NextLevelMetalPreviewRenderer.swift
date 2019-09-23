//
//  NextLevelPreviewMetalView.swift
//  NextLevel (http://nextlevel.engineering/)
//
//  Copyright © 2019 Apple Inc.
//  Copyright (c) 2016-present patrick piemonte (http://patrickpiemonte.com)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import CoreMedia
import Metal
import MetalKit

public class NextLevelPreviewMetalRenderer: NSObject {

    enum Rotation: Int {
        case rotate0Degrees
        case rotate90Degrees
        case rotate180Degrees
        case rotate270Degrees
    }

    enum PreviewContentMode {
        case aspectFit
        case aspectFill
    }

    /// Renders into this view - add it to your view hierarchy
    public var metalBufferView: MTKView?

    var previewContentMode: PreviewContentMode = .aspectFit

    var isEnabled: Bool = true
    
    public var mirrorEdges: Bool = false {
        didSet {
            configureMetal()
            resetTransform  = true
        }
    }

    var shouldAutomaticallyAdjustMirroring: Bool = true

    var mirroring = false {
        didSet {
            syncQueue.sync {
                internalMirroring = mirroring
            }
        }
    }

    private var internalMirroring: Bool = false

    var rotation: Rotation = .rotate0Degrees {
        didSet {
            syncQueue.sync {
                internalRotation = rotation
            }
        }
    }

    private var internalRotation: Rotation = .rotate0Degrees

    var pixelBuffer: CVPixelBuffer? {
        didSet {
            syncQueue.sync {
                guard isEnabled == true else {
                    return
                }
                internalPixelBuffer = pixelBuffer
                self.metalBufferView?.draw()
            }
        }
    }

    private var internalPixelBuffer: CVPixelBuffer?

    private let syncQueue = DispatchQueue(label: "Preview View Sync Queue", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)

    private var textureCache: CVMetalTextureCache?

    private var textureWidth: Int = 0

    private var textureHeight: Int = 0

    private var textureMirroring = false

    private var textureRotation: Rotation = .rotate0Degrees

    private var sampler: MTLSamplerState!

    private var renderPipelineState: MTLRenderPipelineState!

    private var commandQueue: MTLCommandQueue?

    private var vertexCoordBuffer: MTLBuffer!

    private var textCoordBuffer: MTLBuffer!

    private var internalBounds: CGRect!

    private var textureTranform: CGAffineTransform?
    
    private var scaleOffset: SIMD2<Float>?
    
    private var resetTransform: Bool = false

    func texturePointForView(point: CGPoint) -> CGPoint? {
        var result: CGPoint?
        guard let transform = textureTranform else {
            return result
        }
        let transformPoint = point.applying(transform)

        if CGRect(origin: .zero, size: CGSize(width: textureWidth, height: textureHeight)).contains(transformPoint) {
            result = transformPoint
        } else {
            print("Invalid point \(point) result point \(transformPoint)")
        }

        return result
    }

    func viewPointForTexture(point: CGPoint) -> CGPoint? {
        var result: CGPoint?
        guard let transform = textureTranform?.inverted() else {
            return result
        }
        let transformPoint = point.applying(transform)

        if internalBounds.contains(transformPoint) {
            result = transformPoint
        } else {
            print("Invalid point \(point) result point \(transformPoint)")
        }

        return result
    }

    func flushTextureCache() {
        textureCache = nil
    }

    private func setupTransform(width: Int, height: Int, mirroring: Bool, rotation: Rotation) {
        var scaleX: Float = 1.0
        var scaleY: Float = 1.0
        var resizeAspect: Float = 1.0

        internalBounds = metalBufferView?.bounds ?? .zero
        textureWidth = width
        textureHeight = height
        textureMirroring = mirroring
        textureRotation = rotation

        if textureWidth > 0 && textureHeight > 0 {
            switch textureRotation {
            case .rotate0Degrees, .rotate180Degrees:
                scaleX = Float(internalBounds.width / CGFloat(textureWidth))
                scaleY = Float(internalBounds.height / CGFloat(textureHeight))

            case .rotate90Degrees, .rotate270Degrees:
                scaleX = Float(internalBounds.width / CGFloat(textureHeight))
                scaleY = Float(internalBounds.height / CGFloat(textureWidth))
            }
        }
        // Resize aspect ratio.
        resizeAspect = min(scaleX, scaleY)
        let fitComparison = previewContentMode == .aspectFit ? scaleX < scaleY : scaleX > scaleY
        if fitComparison {
            scaleY = scaleX / scaleY
            scaleX = 1.0
        } else {
            scaleX = scaleY / scaleX
            scaleY = 1.0
        }

        if textureMirroring {
            scaleX *= -1.0
        }
        
        var vertScaleX = scaleX
        var vertScaleY = scaleY
        if mirrorEdges {
            vertScaleX = 1.0
            vertScaleY = 1.0
            scaleX = 1.0 / scaleX
            scaleY = 1.0 / scaleY
            scaleOffset = SIMD2<Float>(
                Float((scaleX - 1.0) / 2.0),
                Float((scaleY - 1.0) / 2.0)
            )
        } else {
            scaleOffset = SIMD2<Float>(
                Float(0.0),
                Float(0.0)
            )
        }

        // Vertex coordinate takes the gravity into account.
        let vertexData: [Float] = [
            -vertScaleX, -vertScaleY, 0.0, 1.0,
            vertScaleX, -vertScaleY, 0.0, 1.0,
            -vertScaleX, vertScaleY, 0.0, 1.0,
            vertScaleX, vertScaleY, 0.0, 1.0
        ]
        vertexCoordBuffer = metalBufferView!.device!.makeBuffer(bytes: vertexData, length: vertexData.count * MemoryLayout<Float>.size, options: [])

        // Texture coordinate takes the rotation into account.
        var textData: [Float]
        switch textureRotation {
        case .rotate0Degrees:
            if mirrorEdges {
                textData = [
                    0.0, scaleY,
                    scaleX, scaleY,
                    0.0, 0.0,
                    scaleX, 0.0
                ]
            } else {
               textData = [
                   0.0, 1.0,
                   1.0, 1.0,
                   0.0, 0.0,
                   1.0, 0.0
               ]
            }
        case .rotate180Degrees:
            if mirrorEdges {
                textData = [
                    scaleX, 0.0,
                    0.0, 0.0,
                    scaleX, scaleY,
                    0.0, scaleY
                ]
            } else {
                textData = [
                    1.0, 0.0,
                    0.0, 0.0,
                    1.0, 1.0,
                    0.0, 1.0
                ]
            }
        case .rotate90Degrees:
            if mirrorEdges {
                textData = [
                    scaleY, scaleX,
                    scaleY, 0.0,
                    0.0, scaleX,
                    0.0, 0.0
                ]
            } else {
               textData = [
                   1.0, 1.0,
                   1.0, 0.0,
                   0.0, 1.0,
                   0.0, 0.0
               ]
            }
        case .rotate270Degrees:
            if mirrorEdges {
                textData = [
                    0.0, 0.0,
                    0.0, scaleX,
                    scaleY, 0.0,
                    scaleY, scaleX
                 ]
            } else {
               textData = [
                    0.0, 0.0,
                    0.0, 1.0,
                    1.0, 0.0,
                    1.0, 1.0
                ]
            }
        }
        
        textCoordBuffer = metalBufferView!.device?.makeBuffer(bytes: textData, length: textData.count * MemoryLayout<Float>.size, options: [])

        // Calculate the transform from texture coordinates to view coordinates
        var transform = CGAffineTransform.identity
        if textureMirroring {
            transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1))
            transform = transform.concatenating(CGAffineTransform(translationX: CGFloat(textureWidth), y: 0))
        }

        switch textureRotation {
        case .rotate0Degrees:
            transform = transform.concatenating(CGAffineTransform(rotationAngle: CGFloat(0)))

        case .rotate180Degrees:
            transform = transform.concatenating(CGAffineTransform(rotationAngle: CGFloat(Double.pi)))
            transform = transform.concatenating(CGAffineTransform(translationX: CGFloat(textureWidth), y: CGFloat(textureHeight)))

        case .rotate90Degrees:
            transform = transform.concatenating(CGAffineTransform(rotationAngle: CGFloat(Double.pi) / 2))
            transform = transform.concatenating(CGAffineTransform(translationX: CGFloat(textureHeight), y: 0))

        case .rotate270Degrees:
            transform = transform.concatenating(CGAffineTransform(rotationAngle: 3 * CGFloat(Double.pi) / 2))
            transform = transform.concatenating(CGAffineTransform(translationX: 0, y: CGFloat(textureWidth)))
        }

        transform = transform.concatenating(CGAffineTransform(scaleX: CGFloat(resizeAspect), y: CGFloat(resizeAspect)))
        let tranformRect = CGRect(origin: .zero, size: CGSize(width: textureWidth, height: textureHeight)).applying(transform)
        let xShift = (internalBounds.size.width - tranformRect.size.width) / 2
        let yShift = (internalBounds.size.height - tranformRect.size.height) / 2
        transform = transform.concatenating(CGAffineTransform(translationX: xShift, y: yShift))
        textureTranform = transform.inverted()
    }

    override public init() {
        super.init()
        setup()
    }

    func setup() {

        let metalDevice = MTLCreateSystemDefaultDevice()

        metalBufferView = MTKView(frame: .zero, device: metalDevice)

        guard let bufferView = metalBufferView else {
            fatalError("Unable to make metal buffer view.")
        }

        bufferView.contentScaleFactor = UIScreen.main.nativeScale
        bufferView.framebufferOnly = true
        bufferView.colorPixelFormat = .bgra8Unorm
        bufferView.isPaused = true
        bufferView.enableSetNeedsDisplay = false
        bufferView.delegate = self

        configureMetal()

        createTextureCache()

    }

    func configureMetal() {

        guard let bufferView = metalBufferView else {
            fatalError("Unable to make metal buffer view.")
        }

        let frameworkBundle = Bundle(for: type(of: self))
        var defaultLibrary: MTLLibrary
        do {
            defaultLibrary = try bufferView.device!.makeDefaultLibrary(bundle: frameworkBundle)
            print(defaultLibrary.functionNames)
        } catch {
            fatalError("Unable to make metal default library. (\(error))")
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineDescriptor.vertexFunction = defaultLibrary.makeFunction(name: "vertexPassThrough")
        pipelineDescriptor.fragmentFunction = defaultLibrary.makeFunction(name: "fragmentPassThrough")
        
        // To determine how textures are sampled, create a sampler descriptor to query for a sampler state from the device.
        let samplerDescriptor = MTLSamplerDescriptor()
        
        if mirrorEdges {
            samplerDescriptor.sAddressMode = .mirrorRepeat
            samplerDescriptor.tAddressMode = .mirrorRepeat
        } else {
           samplerDescriptor.sAddressMode = .clampToEdge
           samplerDescriptor.tAddressMode = .clampToEdge
        }
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        sampler = bufferView.device!.makeSamplerState(descriptor: samplerDescriptor)

        do {
            renderPipelineState = try bufferView.device!.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Unable to create preview Metal view pipeline state. (\(error))")
        }

        commandQueue = bufferView.device!.makeCommandQueue()
    }

    func createTextureCache() {

        guard let bufferView = metalBufferView else {
            fatalError("Unable to make metal buffer view.")
        }

        var newTextureCache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, bufferView.device!, nil, &newTextureCache) == kCVReturnSuccess {
            textureCache = newTextureCache
        } else {
            assertionFailure("Unable to allocate texture cache")
        }
    }

}

extension NextLevelPreviewMetalRenderer: MTKViewDelegate {

    final public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }

    final public func draw(in view: MTKView) {

        var pixelBuffer: CVPixelBuffer?
        var mirroring = false
        var rotation: Rotation = .rotate0Degrees

        pixelBuffer = internalPixelBuffer
        mirroring = internalMirroring
        rotation = internalRotation

        guard let drawable = view.currentDrawable,
            let currentRenderPassDescriptor = view.currentRenderPassDescriptor,
            let previewPixelBuffer = pixelBuffer else {
                return
        }

        // Create a Metal texture from the image buffer.
        let width = CVPixelBufferGetWidth(previewPixelBuffer)
        let height = CVPixelBufferGetHeight(previewPixelBuffer)

        if textureCache == nil {
            createTextureCache()
        }
        var cvTextureOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                  textureCache!,
                                                  previewPixelBuffer,
                                                  nil,
                                                  .bgra8Unorm,
                                                  width,
                                                  height,
                                                  0,
                                                  &cvTextureOut)
        guard let cvTexture = cvTextureOut, let texture = CVMetalTextureGetTexture(cvTexture) else {
            print("Failed to create preview texture")

            CVMetalTextureCacheFlush(textureCache!, 0)
            return
        }

        if texture.width != textureWidth ||
            texture.height != textureHeight ||
            view.bounds != internalBounds ||
            mirroring != textureMirroring ||
            rotation != textureRotation ||
            resetTransform {
            setupTransform(width: texture.width, height: texture.height, mirroring: mirroring, rotation: rotation)
            resetTransform = false
        }

        // Set up command buffer and encoder
        guard let commandQueue = commandQueue else {
            print("Failed to create Metal command queue")
            CVMetalTextureCacheFlush(textureCache!, 0)
            return
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            print("Failed to create Metal command buffer")
            CVMetalTextureCacheFlush(textureCache!, 0)
            return
        }

        guard let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: currentRenderPassDescriptor) else {
            print("Failed to create Metal command encoder")
            CVMetalTextureCacheFlush(textureCache!, 0)
            return
        }

        commandEncoder.label = "Preview display"
        commandEncoder.setRenderPipelineState(renderPipelineState!)
        commandEncoder.setVertexBuffer(vertexCoordBuffer, offset: 0, index: 0)
        commandEncoder.setVertexBuffer(textCoordBuffer, offset: 0, index: 1)
        commandEncoder.setFragmentTexture(texture, index: 0)
        commandEncoder.setFragmentSamplerState(sampler, index: 0)
        commandEncoder.setFragmentBytes(&scaleOffset, length: MemoryLayout.size(ofValue: scaleOffset), index: 0)
        commandEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        commandEncoder.endEncoding()

        // Draw to the screen.
        commandBuffer.present(drawable)
        commandBuffer.commit()

    }

}
