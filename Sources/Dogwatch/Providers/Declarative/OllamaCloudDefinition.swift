import Foundation

extension DeclarativeProviders {
    /// Ollama Cloud balances. Current plans report included credits in USD out of the period's
    /// allowance, ending at `period.until`; legacy plans report session and weekly percentages left
    /// instead. Both shapes are optional readings, so whichever the answer has is shown. Purchased
    /// credits (USD, unexpired) come with both. The endpoint allows 10 requests a minute per user,
    /// shared by all of the user's keys and devices, so Dogwatch asks at most every two minutes.
    ///
    /// API reference, read 2026-11-19: https://docs.ollama.com/api/balance.md
    static let ollamaCloud = """
    {
      "id": "ollama-cloud",
      "name": "Ollama Cloud", "tint": "#B0BEC5",
      "stability": "unverified",
      "summary": "Included credits or session and weekly limits, plus purchased credits",
      "source": "Ollama API `GET /api/balance`",
      "documentation": "https://docs.ollama.com/api/balance",
      "glyph": "cloud",
      "keyHelpURL": "https://ollama.com/settings/keys",
      "keyAdvice": "Use an API key from ollama.com settings, not the device key from `ollama signin`. Ollama has no read-only key.",
      "url": "https://ollama.com/api/balance",
      "headers": { "Authorization": "Bearer {key}" },
      "minimumRefreshMinutes": 2,
      "readings": [
        { "id": "included", "name": "Included credits", "kind": "balance", "optional": true,
          "remaining": "included.balance_usd", "total": "included.allowance_usd", "unit": "USD",
          "reset": "included.period.until", "resetFormat": "iso8601" },
        { "id": "session", "name": "Session", "kind": "window", "optional": true, "meterLabel": "Session",
          "remainingPercent": "included.session.remaining_percent", "period": "session",
          "reset": "included.session.resets_at", "resetFormat": "iso8601" },
        { "id": "weekly", "name": "Weekly", "kind": "window", "optional": true, "meterLabel": "Week",
          "remainingPercent": "included.weekly.remaining_percent", "period": "weekly",
          "reset": "included.weekly.resets_at", "resetFormat": "iso8601" },
        { "id": "purchased", "name": "Purchased credits", "kind": "balance",
          "remaining": "purchased.balance_usd", "unit": "USD" }
      ]
    }
    """
}
