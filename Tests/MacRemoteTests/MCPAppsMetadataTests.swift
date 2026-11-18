import Foundation
import Testing
@testable import MacRemote

struct MCPAppsMetadataTests {
    @Test func clientCapabilityRequiresTheFinalHTMLMIMEType() {
        #expect(MCPAppsMetadata.clientSupportsHTMLApp(capabilities: [
            "extensions": MCPAppsMetadata.clientExtensionCapability
        ]))
        #expect(!MCPAppsMetadata.clientSupportsHTMLApp(capabilities: [
            "extensions": [
                MCPAppsMetadata.extensionIdentifier: [
                    "mimeTypes": ["text/html"]
                ]
            ]
        ]))
        #expect(!MCPAppsMetadata.clientSupportsHTMLApp(capabilities: nil))
    }

    /// RFC 9110 lets a host spell the same media type several ways. Rejecting a
    /// legal spelling used to advertise the widget through the legacy aliases
    /// while stripping `_meta.ui` from `resources/read`, so the host was handed
    /// a resource it could not instantiate.
    @Test func clientCapabilityAcceptsEveryLegalSpellingOfTheAppsMediaType() {
        let equivalent = [
            "text/html;profile=mcp-app",
            "text/html; profile=mcp-app",
            "text/html ; profile = mcp-app",
            "text/html;profile=\"mcp-app\"",
            "TEXT/HTML;PROFILE=mcp-app",
            "text/html;profile=mcp-app;",
            // Unrelated parameters are legal and change nothing about the type.
            "text/html;profile=mcp-app;charset=utf-8",
            "text/html; charset=UTF-8; profile=mcp-app",
            "text/html;charset=utf-8;profile=\"mcp-app\""
        ]
        for spelling in equivalent {
            #expect(
                MCPAppsMetadata.isHTMLAppMediaType(spelling),
                "\(spelling) is the Apps media type"
            )
            #expect(MCPAppsMetadata.clientSupportsHTMLApp(capabilities: [
                "extensions": [
                    MCPAppsMetadata.extensionIdentifier: ["mimeTypes": [spelling]]
                ]
            ]))
        }
        // Forgiving about spelling and about extra parameters, never about the
        // profile itself or the type it qualifies.
        for rejected in [
            "text/html",
            "text/html;charset=utf-8",
            "text/html;profile=mcp-app-v2",
            "text/html;profile=MCP-APP",
            "text/html;profile=mcp-app-v2;charset=utf-8",
            "text/html;charset=utf-8;profile=",
            "application/json;profile=mcp-app",
            "text/plain;profile=mcp-app;charset=utf-8",
            ""
        ] {
            #expect(
                !MCPAppsMetadata.isHTMLAppMediaType(rejected),
                "\(rejected) is not the Apps media type"
            )
        }
    }

    @Test func serverCapabilityAdvertisesTheStandardExtensionIdentifier() {
        #expect(
            MCPAppsMetadata.serverExtensionCapability[MCPAppsMetadata.extensionIdentifier]
                is [String: Any]
        )
    }

    @Test func toolMetadataKeepsNestedStandardLinkagePrimaryAndMirrorsCompatible() throws {
        let metadata = MCPAppsMetadata.toolMetadata(merging: [
            "securitySchemes": [["type": "oauth2"]],
            "ui": ["visibility": ["model", "app"]]
        ])
        let ui = try #require(metadata["ui"] as? [String: Any])

        #expect(ui["resourceUri"] as? String == MCPAppsMetadata.resourceURI)
        #expect(ui["visibility"] as? [String] == ["model", "app"])
        #expect(metadata["ui/resourceUri"] as? String == MCPAppsMetadata.resourceURI)
        #expect(metadata["openai/outputTemplate"] as? String == MCPAppsMetadata.resourceURI)
        #expect(metadata["openai/widgetAccessible"] as? Bool == true)
        #expect(metadata["securitySchemes"] != nil)
    }

    @Test func toolMetadataDefaultsVisibilityAndPreservesCallerOverrides() throws {
        let defaults = MCPAppsMetadata.toolMetadata()
        let defaultUI = try #require(defaults["ui"] as? [String: Any])
        #expect(defaultUI["visibility"] as? [String] == ["model", "app"])
        #expect(defaults["openai/widgetAccessible"] as? Bool == true)

        let modelOnly = MCPAppsMetadata.toolMetadata(merging: [
            "ui": ["visibility": ["model"]]
        ])
        let modelOnlyUI = try #require(modelOnly["ui"] as? [String: Any])
        #expect(modelOnlyUI["visibility"] as? [String] == ["model"])
        #expect(modelOnly["openai/widgetAccessible"] as? Bool == false)
    }

    @Test func resourceMetadataMatchesTheWidgetNetworkAndPermissionContract() throws {
        let metadata = MCPAppsMetadata.resourceContentMetadata
        let ui = try #require(metadata["ui"] as? [String: Any])
        let csp = try #require(ui["csp"] as? [String: Any])
        let permissions = try #require(ui["permissions"] as? [String: Any])

        #expect((csp["connectDomains"] as? [String])?.isEmpty == true)
        #expect(csp["resourceDomains"] as? [String] == ["https://static.pocketcasts.com"])
        #expect(permissions["clipboardWrite"] is [String: Any])
        #expect(metadata["openai/widgetDescription"] as? String == MCPAppsMetadata.widgetDescription)
        #expect(
            (metadata["openai/widgetCSP"] as? [String: Any])?["resource_domains"] as? [String]
                == MCPAppsMetadata.resourceDomains
        )
    }

    @Test func resourceDescriptorUsesTheVersionedURIAndSafeSemanticDescription() throws {
        #expect(MCPAppsMetadata.resourceDescriptor["uri"] as? String == MCPAppsMetadata.resourceURI)
        #expect(
            MCPAppsMetadata.resourceDescriptor["mimeType"] as? String
                == "text/html;profile=mcp-app"
        )
        let description = try #require(
            MCPAppsMetadata.resourceDescriptor["description"] as? String
        )
        #expect(description.contains("semantic summaries"))
        #expect(description.contains("attachments"))
        #expect(!description.lowercased().contains("terminal"))
        #expect(!description.lowercased().contains("tree"))
        #expect(MCPAppsMetadata.widgetDescription.contains("semantic summaries"))
        #expect(MCPAppsMetadata.widgetDescription.contains("attachments"))
        #expect(!MCPAppsMetadata.widgetDescription.lowercased().contains("terminal"))
        #expect(!MCPAppsMetadata.widgetDescription.lowercased().contains("tree"))
        #expect(MCPAppsMetadata.resourceURI == "ui://macremote/output-v9.html")
        #expect(MCPAppsMetadata.priorResourceURIs == [
            "ui://macremote/output-v8.html",
            "ui://macremote/output-v7.html",
            "ui://macremote/output-v6.html",
            "ui://macremote/output-v5.html",
            "ui://macremote/output-v4.html",
            "ui://macremote/output-v3.html",
            "ui://macremote/output-v2.html"
        ])
        #expect(MCPAppsMetadata.legacyResourceURI == "ui://macremote/output")
        #expect(MCPAppsMetadata.readableResourceURIs == [
            "ui://macremote/output-v9.html",
            "ui://macremote/output-v8.html",
            "ui://macremote/output-v7.html",
            "ui://macremote/output-v6.html",
            "ui://macremote/output-v5.html",
            "ui://macremote/output-v4.html",
            "ui://macremote/output-v3.html",
            "ui://macremote/output-v2.html",
            "ui://macremote/output"
        ])
        #expect(Set(MCPAppsMetadata.readableResourceURIs).count == 9)
    }

    /// Hosts may read the sandbox policy from the `resources/list` descriptor
    /// or from the `resources/read` content item, and the two must agree — a
    /// host that sandboxes off the listing alone would otherwise block the one
    /// origin the widget loads (podcast artwork).
    @Test func resourceDescriptorDeclaresTheSameSandboxPolicyAsTheReadResult() throws {
        let descriptorMeta = try #require(
            MCPAppsMetadata.resourceDescriptor["_meta"] as? [String: Any]
        )
        let descriptorUI = try #require(descriptorMeta["ui"] as? [String: Any])
        let contentUI = try #require(
            MCPAppsMetadata.resourceContentMetadata["ui"] as? [String: Any]
        )

        #expect(descriptorUI["prefersBorder"] as? Bool == true)
        #expect(
            (descriptorUI["csp"] as? [String: Any])?["resourceDomains"] as? [String]
                == MCPAppsMetadata.resourceDomains
        )
        #expect(
            NSDictionary(dictionary: descriptorUI)
                .isEqual(to: contentUI as [AnyHashable: Any])
        )
    }

    /// Private-beta completeness is measured against the whole first-party
    /// catalog, not only the four presentation profiles that happened to ship
    /// first. A tool without linkage falls back to host-rendered developer
    /// output, which is exactly what the shared widget is meant to prevent.
    @Test func everyFirstPartyCatalogCommandIsWidgetEligible() throws {
        let providerCounts = [
            "alexandria": 10,
            "habitctl": 6,
            "pocketctl": 8,
            "overctl": 9,
            "musicctl": 16,
            "goodlinksctl": 7,
            "frames": 6,
            "iris": 12
        ]
        let fixedCatalogDefinitions =
            AlexandriaToolCatalog.builtInTools
            + OverCTLToolCatalog.builtInTools
            + MusicCTLToolCatalog.builtInTools
        // These builders need an available executable but never launch it in
        // this metadata-only test. A system executable keeps the inventory
        // deterministic on machines without Federico's CLIs.
        let availableFixtureExecutable = "/usr/bin/true"
        let injectedPresets =
            HabitCTLToolPresetCatalog.presets(executablePath: availableFixtureExecutable)
            + PocketCTLToolPresetCatalog.presets(executablePath: availableFixtureExecutable)
            + ReadLaterToolPresetCatalog.presets(executablePath: availableFixtureExecutable)
            + AppleFramesToolPresetCatalog.presets(executablePath: availableFixtureExecutable)
            + IrisToolPresetCatalog.presets(executablePath: availableFixtureExecutable)
        let definitions = fixedCatalogDefinitions + (try injectedPresets.map { preset in
            try preset.draft.makeTool(id: preset.toolID)
        })

        try #require(definitions.count == 74, "The first-party inventory must stay complete.")
        for (provider, expectedCount) in providerCounts {
            let prefix = "\(provider)_"
            #expect(
                definitions.filter { $0.id.hasPrefix(prefix) }.count == expectedCount,
                "Unexpected \(provider) command inventory."
            )
        }

        let missing = definitions
            .filter { LocalMCPServer.widgetEligible(tool: $0) == false }
            .map(\.id)
            .sorted()
        #expect(
            missing.isEmpty == true,
            "Every first-party command needs MCP Apps linkage. Missing: \(missing.joined(separator: ", "))"
        )

        let flexible = definitions.filter(\.isGenericCLIAdapter)
        #expect(flexible.count == 8, "Each provider must keep one Flexible Command.")
        #expect(
            flexible.allSatisfy { LocalMCPServer.widgetEligible(tool: $0) },
            "Flexible Commands need the safe generic widget fallback too."
        )
    }
}
