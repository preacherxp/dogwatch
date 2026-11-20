import Foundation

extension DeclarativeProviders {
    /// Novita AI balance. Every amount is a string in 1/10,000 of a US dollar ("10000" = $1.00),
    /// hence `scale` 0.0001.
    ///
    /// API reference, read 2026-11-19: https://docs.novita.ai/api-reference/basic-get-user-balance.md
    static let novita = """
    {
      "id": "novita",
      "name": "Novita AI", "tint": "#2BB673",
      "stability": "unverified",
      "summary": "Available balance and cash (USD)",
      "source": "Novita API `GET /openapi/v1/billing/balance/detail`",
      "documentation": "https://docs.novita.ai/api-reference/basic-get-user-balance",
      "glyph": "n.square",
      "keyHelpURL": "https://docs.novita.ai/guides/quickstart",
      "keyAdvice": "Novita has no read-only key; any API key can read the balance.",
      "url": "https://api.novita.ai/openapi/v1/billing/balance/detail",
      "headers": { "Authorization": "Bearer {key}" },
      "readings": [
        { "id": "balance", "name": "Available balance", "kind": "balance",
          "remaining": "availableBalance", "unit": "USD", "scale": 0.0001 },
        { "id": "cash", "name": "Cash", "kind": "balance",
          "remaining": "cashBalance", "unit": "USD", "scale": 0.0001 }
      ],
      "primary": "balance"
    }
    """
}
