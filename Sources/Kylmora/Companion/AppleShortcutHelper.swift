import AppKit
import Foundation

/// Helpers to generate and export Apple Shortcuts for iPhone and iPad (F-35).
public enum AppleShortcutHelper {

    /// Generates markdown / plain text instructions for setting up the Apple Shortcut on iOS.
    public static func generateShortcutInstructions() -> String {
        """
        # Kylmora: Send Links from iPhone / iPad to your Spaces

        You can send links from Safari, Twitter, Threads, Reddit, or any iOS app directly into a chosen Space in Kylmora (e.g. "Read Later", "Work", or "Research").

        ### How it works:
        1. When you share a link on iPhone, an Apple Shortcut writes a tiny JSON file into:
           `iCloud Drive/Kylmora/Inbox/`
        2. Kylmora on your Mac monitors this iCloud folder, reads the link, immediately opens it in your chosen Space (or Pinned Sites), and removes the file.

        ---

        ### Option A: Ready-Made Shortcut
        1. On your iPhone, open the Files app.
        2. Navigate to: `iCloud Drive > Kylmora > Send to Kylmora.shortcut`
        3. Tap the file to import it into the Apple Shortcuts app.
        4. Enable "Show in Share Sheet" in Shortcut details.

        ---

        ### Option B: Build it yourself in 60 seconds (iOS Shortcuts app)
        1. Open the **Shortcuts** app on your iPhone and tap `+` (New Shortcut).
        2. Tap the info button `(i)` at the bottom and turn ON:
           - **Show in Share Sheet**
           - Receive: **URLs, Safari web pages, Text**
        3. Add action: **Dictionary**
           - Add Key `url` = `Shortcut Input`
           - Add Key `title` = `Name` (from Shortcut Input)
           - Add Key `space` = `Read Later` (or choose "Ask Each Time")
           - Add Key `sender` = `iPhone`
        4. Add action: **Set Name**
           - Set name of `Dictionary` to: `link-[Current Date: yyyyMMdd-HHmmss].json`
        5. Add action: **Save File**
           - File: `Renamed Item`
           - Service: **iCloud Drive**
           - Destination Path: `Kylmora/Inbox`
           - Turn OFF "Ask Where to Save"
           - Turn ON "Overwrite If File Exists"
        6. Tap **Done**!

        Now, whenever you find an article or site on your iPhone, tap Share -> "Send to Kylmora", and it will appear on your Mac instantly!
        """
    }

    /// Generates a valid Apple Shortcut JSON / property dictionary suitable for iOS Shortcuts import.
    public static func generateShortcutPayload() -> [String: Any] {
        [
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowTypes": ["ActionExtension"],
            "WFWorkflowInputContentItemClasses": ["WFURLContentItem", "WFSafariWebPageContentItem", "WFStringContentItem"],
            "WFWorkflowActions": [
                [
                    "WFWorkflowActionIdentifier": "is.workflow.actions.dictionary",
                    "WFWorkflowActionParameters": [
                        "WFItems": [
                            "Value": [
                                "WFDictionaryFieldValueItems": [
                                    [
                                        "WFKey": [
                                            "Value": ["string": "url"],
                                            "WFSerializationType": "WFTextTokenString"
                                        ],
                                        "WFItemType": 0,
                                        "WFValue": [
                                            "Value": [
                                                "attachmentsByRange": [
                                                    "{0, 1}": [
                                                        "Type": "ExtensionInput"
                                                    ]
                                                ],
                                                "string": "\u{FFFC}"
                                            ],
                                            "WFSerializationType": "WFTextTokenString"
                                        ]
                                    ],
                                    [
                                        "WFKey": [
                                            "Value": ["string": "space"],
                                            "WFSerializationType": "WFTextTokenString"
                                        ],
                                        "WFItemType": 0,
                                        "WFValue": [
                                            "Value": ["string": "Read Later"],
                                            "WFSerializationType": "WFTextTokenString"
                                        ]
                                    ],
                                    [
                                        "WFKey": [
                                            "Value": ["string": "sender"],
                                            "WFSerializationType": "WFTextTokenString"
                                        ],
                                        "WFItemType": 0,
                                        "WFValue": [
                                            "Value": ["string": "iPhone"],
                                            "WFSerializationType": "WFTextTokenString"
                                        ]
                                    ]
                                ]
                            ],
                            "WFSerializationType": "WFDictionaryFieldValue"
                        ]
                    ]
                ],
                [
                    "WFWorkflowActionIdentifier": "is.workflow.actions.documentpicker.save",
                    "WFWorkflowActionParameters": [
                        "WFFolder": "Kylmora/Inbox",
                        "WFAskWhereToSave": false,
                        "WFSaveFileOverwrite": true
                    ]
                ]
            ]
        ]
    }

    /// Exports the shortcut file and setup guide into the designated directory (or iCloud Drive).
    public static func exportShortcutBundle(to directoryURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let instructionsURL = directoryURL.appending(path: "iPhone-ShareSheet-Setup.txt")
        let instructions = generateShortcutInstructions()
        try instructions.write(to: instructionsURL, atomically: true, encoding: .utf8)

        let shortcutURL = directoryURL.appending(path: "Send to Kylmora.shortcut")
        let payload = generateShortcutPayload()
        let plistData = try PropertyListSerialization.data(fromPropertyList: payload, format: .binary, options: 0)
        try plistData.write(to: shortcutURL, options: [.atomic])
    }
}
