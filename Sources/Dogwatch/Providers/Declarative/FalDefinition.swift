import Foundation

extension DeclarativeProviders {
    /// fal credit balance in the currency the answer names. Needs `?expand=credits`, and a key
    /// with `billing:usage:read` (the BILLING and READONLY presets have it). The scheme is `Key`.
    ///
    /// API reference, read 2026-11-19: https://fal.ai/docs/platform-apis/v1/account/billing
    static let fal = """
    {
      "id": "fal",
      "name": "fal", "tint": "#EC4899",
      "stability": "unverified",
      "summary": "Credit balance",
      "source": "fal Platform API `GET /v1/account/billing`",
      "documentation": "https://fal.ai/docs/platform-apis/v1/account/billing",
      "glyph": "photo.stack",
      "keyHelpURL": "https://fal.ai/docs/authentication/key-based",
      "keyAdvice": "Create a key with the BILLING or READONLY preset. It needs billing:usage:read, and can't run models.",
      "url": "https://api.fal.ai/v1/account/billing?expand=credits",
      "headers": { "Authorization": "Key {key}" },
      "readings": [
        { "id": "balance", "name": "Credit balance", "kind": "balance",
          "remaining": "credits.current_balance", "unit": "$.credits.currency" }
      ]
    }
    """
}
