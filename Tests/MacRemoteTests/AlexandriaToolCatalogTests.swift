import Foundation
import Testing
@testable import MacRemote

@Suite("Alexandria semantic catalog")
struct AlexandriaToolCatalogTests {
    @Test("Sparse surface is nine dedicated workflows plus one escape hatch")
    func surface() {
        #expect(AlexandriaToolCatalog.builtInTools.map(\.id) == [
            "alexandria_health", "alexandria_list_resources",
            "alexandria_browse_room", "alexandria_search_notes",
            "alexandria_show_note", "alexandria_capture_clip",
            "alexandria_capture_in_room", "alexandria_run_agent",
            "alexandria_wait_job", "alexandria_run"
        ])
        #expect(AlexandriaToolCatalog.builtInTools.allSatisfy { $0.category == .ai })
        #expect(AlexandriaToolCatalog.builtInTools.allSatisfy {
            $0.permissionRequirements.isEmpty
        })
        #expect(AlexandriaToolCatalog.fullCLITool.approvalPolicy == .everyCall)
    }

    @Test("Room browsing uses bounded typed filters")
    func browseRoom() throws {
        let arguments = try AlexandriaToolCatalog.arguments(
            for: "alexandria_browse_room",
            parameters: [
                "view_id": .string("view-recipes"),
                "search": .string("soup"),
                "tag": .string("article")
            ]
        )
        #expect(arguments == [
            "--json", "views", "items", "view-recipes",
            "--search", "soup", "--tag", "article",
            "--limit", "100", "--offset", "0"
        ])
    }

    @Test("Capture sends content through stdin and uses one literal stdin marker")
    func capture() throws {
        let tool = try #require(AlexandriaToolCatalog.tool(id: "alexandria_capture_clip"))
        let arguments = try AlexandriaToolCatalog.arguments(
            for: tool.id,
            parameters: [
                "stdin": .string("https://example.com"),
                "title": .string("Example")
            ]
        )
        #expect(arguments == [
            "--json", "notes", "capture", "-", "--title", "Example"
        ])
        #expect(tool.capability == .write)
        #expect(tool.annotationOverrides?.openWorldHint == true)
    }

    @Test("Agent execution is enqueue-only and asks every time")
    func runAgent() throws {
        let tool = try #require(AlexandriaToolCatalog.tool(id: "alexandria_run_agent"))
        #expect(tool.approvalPolicy == .everyCall)
        #expect(tool.annotationOverrides?.openWorldHint == true)
        #expect(try AlexandriaToolCatalog.arguments(
            for: tool.id,
            parameters: [
                "agent": .string("web-clipper"),
                "note_uuid": .string("ABC")
            ]
        ) == [
            "--json", "agents", "run", "web-clipper", "--note-uuid", "ABC"
        ])
    }
}
