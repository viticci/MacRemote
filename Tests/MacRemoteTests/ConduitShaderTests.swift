import Foundation
import Metal
import Testing
@testable import MacRemote

/// The Liquid Light Conduit ships as a precompiled metallib (the CLT host has
/// no Metal compiler). These tests catch the two silent failure modes: the
/// resource missing from the module bundle, and a metallib that no longer
/// exports the function ConduitLightLayer asks SwiftUI to stitch.
struct ConduitShaderTests {
    @Test func metallibShipsInModuleBundle() throws {
        let url = Bundle.module.url(forResource: "default", withExtension: "metallib")
        #expect(url != nil)
    }

    @Test func metallibExportsConduitLight() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device on this machine — cannot validate the shader library.")
            return
        }
        // @testable import exposes the app module's generated Bundle.module,
        // which SwiftPM resolves to MacRemote_MacRemote.bundle in the build
        // products directory — the same bundle the app loads at runtime.
        let url = try #require(Bundle.module.url(forResource: "default", withExtension: "metallib"))
        let library = try device.makeLibrary(URL: url)
        #expect(library.functionNames.contains("conduitLight"))
    }
}
