import Foundation
import Testing
@testable import PummelchenCore

@Suite("Minecraft client defaults")
struct MinecraftClientDefaultsTests {
    @Test("applies visual and config defaults idempotently")
    func appliesDefaultsIdempotently() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pummelchen-minecraft-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let options = root.appendingPathComponent("options.txt")
        try """
        resourcePacks:["vanilla","file/Old Pack"]
        incompatibleResourcePacks:["file/Old Pack"]
        resourcePacks:["duplicate"]
        simulationDistance:5
        """.write(to: options, atomically: true, encoding: .utf8)

        try MinecraftClientDefaultWriter.apply(to: root)
        try MinecraftClientDefaultWriter.apply(to: root)

        let optionsText = try String(contentsOf: options, encoding: .utf8)
        #expect(optionsText.contains(#"resourcePacks:["vanilla","mod_resources","file/ModernArch v2.8.2 [26.1] [128x].zip","file/ModernArch FA Extension v2.2.zip","file/ModernArch Denser Grass Addon.zip"]"#))
        #expect(optionsText.contains("incompatibleResourcePacks:[]"))
        #expect(optionsText.contains("simulationDistance:5"))
        #expect(optionsText.components(separatedBy: "resourcePacks:").count == 2)

        let iris = try String(contentsOf: root.appendingPathComponent("config/iris.properties"), encoding: .utf8)
        #expect(iris.contains("shaderPack=BSL_v10.1.3.zip"))
        #expect(iris.contains("enableShaders=true"))
        #expect(iris.contains("maxShadowRenderDistance=32"))

        let shaderOptions = try String(contentsOf: root.appendingPathComponent("optionsshaders.txt"), encoding: .utf8)
        #expect(shaderOptions.contains("shaderPack=BSL_v10.1.3.zip"))

        let ducks = try String(contentsOf: root.appendingPathComponent("config/untitledduckmod-server.toml"), encoding: .utf8)
        #expect(ducks.contains("duck_tamed_no_follow=true"))
        #expect(ducks.contains("goose_tamed_no_follow=true"))
    }
}
