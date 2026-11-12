import Foundation
import Testing
@testable import MacRemote

struct MCPBridgeToolResultNormalizerTests {
    @Test func structuredContentUnwrapsWhenFallbackIsEquivalentJSON() {
        let normalized = MCPBridgeToolResultNormalizer.normalize([
            "content": [["type": "text", "text": #"{ "items": [ { "id": "one" } ] }"#]],
            "structuredContent": ["items": [["id": "one"]]],
            "isError": false
        ])

        #expect(normalized.stdout == #"{"items":[{"id":"one"}]}"#)
        #expect(!normalized.isError)
        #expect(normalized.upstreamContext == nil)
    }

    @Test func distinctFallbackIsForwardedBesideDirectStructuredPayload() {
        let normalized = MCPBridgeToolResultNormalizer.normalize([
            "content": [["type": "text", "text": "One item was returned."]],
            "structuredContent": ["items": [["id": "one"]]],
            "isError": false
        ])

        #expect(normalized.stdout == #"{"items":[{"id":"one"}]}"#)
        #expect(normalized.upstreamContext?.content == [
            .object(["type": .string("text"), "text": .string("One item was returned.")])
        ])
        #expect(normalized.upstreamContext?.meta == nil)
        #expect(normalized.encodedByteCount > normalized.stdout.utf8.count)
    }

    @Test func structuredContentKeepsResultMetadataInTypedContext() {
        let normalized = MCPBridgeToolResultNormalizer.normalize([
            "content": [["type": "text", "text": #"{"items":[]}"#]],
            "structuredContent": ["items": []],
            "isError": false,
            "_meta": ["cursor": "next"]
        ])

        #expect(normalized.stdout == #"{"items":[]}"#)
        #expect(normalized.upstreamContext?.content.isEmpty == true)
        #expect(normalized.upstreamContext?.meta == .object(["cursor": .string("next")]))
    }

    @Test func soleBareTextIsDirectWithoutRedundantPassthrough() {
        let text = #"{"data":[{"id":"post-1"}]}"#
        let normalized = MCPBridgeToolResultNormalizer.normalize([
            "content": [["type": "text", "text": text]],
            "isError": false
        ])

        #expect(normalized.stdout == text)
        #expect(!normalized.isError)
        #expect(normalized.upstreamContext == nil)
    }

    @Test func nullStructuredContentRemainsTheSemanticPayload() {
        let normalized = MCPBridgeToolResultNormalizer.normalize([
            "content": [["type": "text", "text": "null"]],
            "structuredContent": NSNull(),
            "isError": false
        ])

        #expect(normalized.stdout == "null")
        #expect(normalized.upstreamContext == nil)
    }

    @Test func arrayAndPrimitiveStructuredContentRemainExactJSON() {
        let cases: [(Any, String)] = [
            ([["id": "one"], ["id": "two"]], #"[{"id":"one"},{"id":"two"}]"#),
            ("hello", #""hello""#),
            (NSNumber(value: Int64(0)), "0"),
            (NSNumber(value: Int64(1)), "1"),
            (true, "true"),
            (false, "false"),
            (NSNumber(value: 1.25), "1.25")
        ]

        for (value, expected) in cases {
            let normalized = MCPBridgeToolResultNormalizer.normalize([
                "content": [["type": "text", "text": expected]],
                "structuredContent": value,
                "isError": false
            ])

            #expect(normalized.stdout == expected)
            #expect(normalized.upstreamContext == nil)
        }
    }

    @Test func structuredContentPreservesLargeIntegerAndDecimalText() {
        let cases: [(Any, String)] = [
            (NSNumber(value: Int64(9_007_199_254_740_993)), "9007199254740993"),
            (NSNumber(value: Int64.max), "9223372036854775807"),
            (NSNumber(value: UInt64.max), "18446744073709551615"),
            (
                NSDecimalNumber(
                    string: "12345678901234567890.123456789",
                    locale: Locale(identifier: "en_US_POSIX")
                ),
                "12345678901234567890.123456789"
            )
        ]

        for (value, expected) in cases {
            let normalized = MCPBridgeToolResultNormalizer.normalize([
                "content": [["type": "text", "text": expected]],
                "structuredContent": value,
                "isError": false
            ])

            #expect(normalized.stdout == expected)
            #expect(normalized.upstreamContext == nil)
        }
    }

    @Test func nonJSONStructuredContentDoesNotBecomeSemanticStdout() {
        for invalidValue in [Double.nan as Any, Double.infinity as Any, Date() as Any] {
            let normalized = MCPBridgeToolResultNormalizer.normalize([
                "content": [["type": "text", "text": "safe fallback"]],
                "structuredContent": invalidValue,
                "isError": false
            ])

            #expect(normalized.stdout == "safe fallback")
            #expect(normalized.upstreamContext?.content.count == 1)
        }
    }

    @Test func multimodalContentUsesDirectArrayAndPreservesTypedBlocks() {
        let normalized = MCPBridgeToolResultNormalizer.normalize([
            "content": [
                ["type": "text", "text": "caption"],
                ["type": "image", "data": "AA==", "mimeType": "image/png"]
            ],
            "isError": false
        ])

        #expect(normalized.stdout == #"[{"text":"caption","type":"text"},{"data":"AA==","mimeType":"image/png","type":"image"}]"#)
        #expect(normalized.upstreamContext?.content.count == 2)
        #expect(normalized.upstreamContext?.content[1].objectValue?["type"] == .string("image"))
    }

    @Test func annotatedTextStaysDirectAndPreservesTheAnnotatedBlock() {
        let normalized = MCPBridgeToolResultNormalizer.normalize([
            "content": [[
                "type": "text",
                "text": "caption",
                "annotations": ["audience": ["assistant"]]
            ]],
            "isError": false
        ])

        #expect(normalized.stdout == "caption")
        #expect(normalized.upstreamContext?.content.count == 1)
        #expect(
            normalized.upstreamContext?.content[0].objectValue?["annotations"]
                == .object(["audience": .array([.string("assistant")])])
        )
    }

    @Test func soleUserOnlyTextNeverEntersSemanticStdout() {
        let privateText = "Only the person should see this."
        let normalized = MCPBridgeToolResultNormalizer.normalize([
            "content": [[
                "type": "text",
                "text": privateText,
                "annotations": ["audience": ["user"]]
            ]],
            "isError": false
        ])

        #expect(normalized.stdout.isEmpty)
        #expect(!normalized.stdout.contains(privateText))
        #expect(normalized.upstreamContext?.assistantVisibleContent.isEmpty == true)
        #expect(normalized.upstreamContext?.userOnlyContent.count == 1)
        #expect(
            normalized.upstreamContext?.userOnlyContent[0].objectValue?["text"]
                == .string(privateText)
        )
    }

    @Test func mixedAudienceStdoutContainsOnlyAssistantVisibleBlocks() {
        let privateText = "private-user-detail"
        let normalized = MCPBridgeToolResultNormalizer.normalize([
            "content": [
                [
                    "type": "text",
                    "text": "assistant-detail",
                    "annotations": ["audience": ["assistant"]]
                ],
                [
                    "type": "text",
                    "text": privateText,
                    "annotations": ["audience": ["user"]]
                ],
                [
                    "type": "text",
                    "text": "shared-detail",
                    "annotations": ["audience": ["user", "assistant"]]
                ]
            ],
            "isError": false
        ])

        #expect(normalized.stdout.contains("assistant-detail"))
        #expect(normalized.stdout.contains("shared-detail"))
        #expect(!normalized.stdout.contains(privateText))
        #expect(normalized.upstreamContext?.assistantVisibleContent.count == 2)
        #expect(normalized.upstreamContext?.userOnlyContent.count == 1)
    }

    @Test func nonstandardTopLevelFieldsArePreservedGenerically() {
        let normalized = MCPBridgeToolResultNormalizer.normalize([
            "content": [["type": "text", "text": "ok"]],
            "isError": false,
            "vendorCursor": "cursor-2"
        ])

        #expect(normalized.stdout == "ok")
        #expect(normalized.upstreamContext?.content.isEmpty == true)
        #expect(normalized.upstreamContext?.extensions == [
            "vendorCursor": .string("cursor-2")
        ])
    }

    @Test func upstreamIsErrorIsPreserved() {
        let normalized = MCPBridgeToolResultNormalizer.normalize([
            "content": [["type": "text", "text": "denied"]],
            "isError": true
        ])

        #expect(normalized.stdout == "denied")
        #expect(normalized.isError)
        #expect(normalized.upstreamContext == nil)
    }

    @Test func typedContextDistinguishesZeroAndOneFromBooleansAndPreservesLargeIntegers() throws {
        let source = #"{"content":[{"type":"text","text":"annotated","annotations":{"priority":1,"zero":0,"enabled":true},"recordID":9007199254740993}],"isError":false}"#
        let result = try #require(
            JSONSerialization.jsonObject(with: Data(source.utf8)) as? [String: Any]
        )

        let normalized = MCPBridgeToolResultNormalizer.normalize(result)
        let context = try #require(normalized.upstreamContext)
        let encoded = try JSONSerialization.data(
            withJSONObject: context.preservationJSONObject,
            options: [.sortedKeys]
        )
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(text.contains(#""priority":1"#))
        #expect(text.contains(#""zero":0"#))
        #expect(text.contains(#""enabled":true"#))
        #expect(text.contains(#""recordID":9007199254740993"#))
        #expect(!text.contains(#""priority":true"#))
    }

    @Test func emptyContentKeepsMetadataHiddenAndProducesEmptySemanticStdout() {
        let normalized = MCPBridgeToolResultNormalizer.normalize([
            "content": [],
            "_meta": ["privateCursor": "cursor-1"],
            "isError": false
        ])

        #expect(normalized.stdout.isEmpty)
        #expect(normalized.upstreamContext?.content.isEmpty == true)
        #expect(
            normalized.upstreamContext?.meta
                == .object(["privateCursor": .string("cursor-1")])
        )
        #expect(!normalized.stdout.contains("privateCursor"))
    }
}
