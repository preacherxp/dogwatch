import Foundation

extension DeclarativeProviders {
    /// AI/ML API balance. `current_balance` is in the answer's `currency`, documented as always USD.
    ///
    /// API reference, read 2026-11-19: https://docs.aimlapi.com/api-references/service-endpoints/account-balance.md
    static let aimlapi = """
    {
      "id": "aimlapi",
      "name": "AI/ML API", "tint": "#9B6BDF",
      "stability": "unverified",
      "summary": "Balance (USD)",
      "source": "AI/ML API `GET /v2/billing`",
      "documentation": "https://docs.aimlapi.com/api-references/service-endpoints/account-balance",
      "glyph": "creditcard",
      "keyHelpURL": "https://aimlapi.com/app/keys",
      "keyAdvice": "Use a regular API key; a management key is refused for billing.",
      "url": "https://api.aimlapi.com/v2/billing",
      "headers": { "Authorization": "Bearer {key}" },
      "readings": [
        { "id": "balance", "name": "Balance", "kind": "balance",
          "remaining": "current_balance", "unit": "$.currency" }
      ]
    }
    """
}
