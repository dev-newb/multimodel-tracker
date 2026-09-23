// Minimal transport dependencies for compiling the real parsers without an AppKit app entry point.
import Foundation
enum Keychain { struct OpenAICreds { let accessToken: String; let accountId: String? } }
enum AnthropicOAuth { static let betaHeader = "oauth-2025-04-20" }
enum AdapterError: Error { case transport(String), notSignedIn }
