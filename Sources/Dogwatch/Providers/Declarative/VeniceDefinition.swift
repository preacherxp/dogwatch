import Foundation

extension DeclarativeProviders {
    /// Venice balances: USD (documented as null when zero, so null reads as $0), DIEM left of the
    /// epoch's allocation (null when not staking), bundled and earned credits. The primary is the
    /// one Venice says it is spending (`consumptionCurrency`). Venice marks its billing API as beta.
    ///
    /// API reference, read 2026-11-19: https://docs.venice.ai/api-reference/endpoint/billing/balance.md
    static let venice = """
    {
      "id": "venice",
      "name": "Venice AI", "tint": "#C9A227",
      "stability": "unverified",
      "summary": "USD, DIEM and credit balances",
      "source": "Venice API `GET /api/v1/billing/balance` (beta)",
      "documentation": "https://docs.venice.ai/api-reference/endpoint/billing/balance",
      "glyph": "v.square",
      "keyHelpURL": "https://docs.venice.ai/overview/guides/generating-api-key",
      "keyAdvice": "Venice has no read-only key. An IP-restricted key fails here unless this Mac's address is allowed.",
      "url": "https://api.venice.ai/api/v1/billing/balance",
      "headers": { "Authorization": "Bearer {key}" },
      "readings": [
        { "id": "usd", "name": "USD balance", "kind": "balance",
          "remaining": "balances.usd", "unit": "USD", "nullIsZero": true },
        { "id": "diem", "name": "DIEM", "kind": "balance",
          "remaining": "balances.diem", "total": "diemEpochAllocation", "unit": "DIEM" },
        { "id": "bundled", "name": "Bundled credits", "kind": "balance",
          "remaining": "balances.bundledCredits", "unit": "credits" },
        { "id": "earned", "name": "Earned credits", "kind": "balance",
          "remaining": "balances.earnedCredits", "unit": "credits" }
      ],
      "primaryFrom": { "path": "consumptionCurrency",
        "readings": { "USD": "usd", "DIEM": "diem", "BUNDLED_CREDITS": "bundled", "EARNED_CREDITS": "earned" } }
    }
    """
}
