import Foundation

extension DeclarativeProviders {
    /// Hyperbolic balance. `balanceCents` is a number of US cents, hence `scale` 0.01. The
    /// deprecated `/v2/alpha/customer/balance` path stops on 2027-03-01 and isn't used.
    ///
    /// API reference, read 2026-11-19: https://hyperbolic.ai/docs/api-reference/balances/get-the-current-user-or-organization-accounts-balance.md (unit: https://hyperbolic.ai/docs/general/billing-payments.md, credits are 1:1 with US dollars)
    static let hyperbolic = """
    {
      "id": "hyperbolic",
      "name": "Hyperbolic", "tint": "#E85D75",
      "stability": "unverified",
      "summary": "Credit balance (USD)",
      "source": "Hyperbolic API `GET /v2/customer/balance`",
      "documentation": "https://hyperbolic.ai/docs/api-reference/balances/get-the-current-user-or-organization-accounts-balance",
      "glyph": "h.square",
      "keyHelpURL": "https://hyperbolic.ai/docs/inference/overview",
      "keyAdvice": "Hyperbolic has no read-only key; any API key can read the balance.",
      "url": "https://api.hyperbolic.ai/v2/customer/balance",
      "headers": { "Authorization": "Bearer {key}" },
      "readings": [
        { "id": "balance", "name": "Balance", "kind": "balance",
          "remaining": "balanceCents", "unit": "USD", "scale": 0.01 }
      ]
    }
    """
}
