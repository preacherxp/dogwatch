import Foundation

extension DeclarativeProviders {
    /// Stability AI credit balance, a number of credits (fractional). Stability prices one credit
    /// at $0.01; the reading stays in credits, as Stability shows it.
    ///
    /// API reference, read 2026-11-19: https://docs.stability.ai/api-reference/user/account-balance.md
    static let stability = """
    {
      "id": "stability",
      "name": "Stability AI", "tint": "#A855F7",
      "stability": "unverified",
      "summary": "Credit balance",
      "source": "Stability API `GET /v1/user/balance`",
      "documentation": "https://docs.stability.ai/api-reference/user/account-balance",
      "glyph": "paintbrush",
      "keyPlaceholder": "sk-…",
      "keyHelpURL": "https://platform.stability.ai/dashboard/api-keys",
      "keyAdvice": "Stability has no read-only key; any API key can read the balance.",
      "url": "https://api.stability.ai/v1/user/balance",
      "headers": { "Authorization": "Bearer {key}" },
      "readings": [
        { "id": "credits", "name": "Credits", "kind": "balance",
          "remaining": "credits", "unit": "credits" }
      ]
    }
    """
}
