// Offscreen preview of Shaders/ConduitLight.metal — renders previewGrid frames
// to PNG so the shader can be reviewed without launching the app.
// Usage: swift script/render_shader_preview.swift <outdir> [t0 t1 t2 ...]
// Compiles the .metal SOURCE at runtime (no Metal toolchain required).

import AppKit
import Foundation
import Metal

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: render_shader_preview.swift <outdir> [times...]\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let times = args.count > 2 ? args[2...].compactMap { Float($0) } : [0, 1.3, 2.6, 4.0, 5.2]

let scriptURL = URL(fileURLWithPath: #filePath)
let shaderURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Shaders/ConduitLight.metal")
let source = try String(contentsOf: shaderURL, encoding: .utf8)

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
let library = try device.makeLibrary(source: source, options: nil)
guard let fn = library.makeFunction(name: "previewGrid") else { fatalError("previewGrid missing") }
let pipeline = try device.makeComputePipelineState(function: fn)
let queue = device.makeCommandQueue()!

let width = 920, height = 120   // ~2x the on-screen pill
let desc = MTLTextureDescriptor.texture2DDescriptor(
    pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
desc.usage = [.shaderWrite, .shaderRead]

for t in times {
    let texture = device.makeTexture(descriptor: desc)!
    var time = t
    var tint: [Float] = [0.20, 0.78, 0.35, 1.0]   // system green-ish

    let cmd = queue.makeCommandBuffer()!
    let enc = cmd.makeComputeCommandEncoder()!
    enc.setComputePipelineState(pipeline)
    enc.setTexture(texture, index: 0)
    enc.setBytes(&time, length: MemoryLayout<Float>.size, index: 0)
    enc.setBytes(&tint, length: MemoryLayout<Float>.size * 4, index: 1)
    let tg = MTLSize(width: 16, height: 16, depth: 1)
    let grid = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
    enc.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
    enc.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    // Read back as float16 → 8-bit RGBA
    var half16 = [UInt16](repeating: 0, count: width * height * 4)
    texture.getBytes(&half16, bytesPerRow: width * 8, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    func h2f(_ h: UInt16) -> Float {
        let sign = UInt32(h >> 15) & 1, exp = UInt32(h >> 10) & 0x1F, man = UInt32(h) & 0x3FF
        var bits: UInt32
        if exp == 0 { bits = sign << 31 }  // flush denormals
        else if exp == 31 { bits = (sign << 31) | 0x7F800000 | (man << 13) }
        else { bits = (sign << 31) | ((exp + 112) << 23) | (man << 13) }
        return Float(bitPattern: bits)
    }
    var rgba8 = [UInt8](repeating: 0, count: width * height * 4)
    for i in 0..<(width * height * 4) {
        rgba8[i] = UInt8(max(0, min(255, h2f(half16[i]) * 255)))
    }
    let provider = CGDataProvider(data: Data(rgba8) as CFData)!
    let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                     bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let rep = NSBitmapImageRep(cgImage: cg)
    let png = rep.representation(using: .png, properties: [:])!
    let name = String(format: "frame_t%05.2f.png", t)
    try png.write(to: outDir.appendingPathComponent(name))
    print("wrote \(name)")
}
