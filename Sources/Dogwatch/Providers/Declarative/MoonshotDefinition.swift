import Foundation

extension DeclarativeProviders {
    /// Moonshot / Kimi API balance. The same endpoint answers in USD on api.moonshot.ai and in
    /// CNY on api.moonshot.cn, as each platform's reference states, so the unit follows the region
    /// picked in settings. Keys of the two platforms are separate. `code` 0 means success.
    ///
    /// API reference, read 2026-11-19: https://platform.kimi.ai/docs/api/balance.md (international, USD) and https://platform.kimi.com/docs/api/balance.md (China, CNY)
    static let moonshot = """
    {
      "id": "moonshot",
      "name": "Kimi API (Moonshot)", "tint": "#6366F1",
      "stability": "unverified",
      "summary": "Available balance, voucher and cash (USD or CNY by region)",
      "source": "Moonshot API `GET /v1/users/me/balance`",
      "documentation": "https://platform.kimi.ai/docs/api/balance",
      "glyph": "moon.stars",
      "keyPlaceholder": "sk-…",
      "keyHelpURL": "https://platform.kimi.ai/console/api-keys",
      "keyAdvice": "Moonshot has no read-only key. A key from platform.kimi.ai works only with the International region, one from platform.kimi.com only with China.",
      "baseURLs": [
        { "label": "International (USD)", "url": "https://api.moonshot.ai", "unit": "USD" },
        { "label": "China (CNY)", "url": "https://api.moonshot.cn", "unit": "CNY" }
      ],
      "url": "{baseURL}/v1/users/me/balance",
      "headers": { "Authorization": "Bearer {key}" },
      "okWhen": { "path": "code", "equals": 0 },
      "readings": [
        { "id": "balance", "name": "Available balance", "kind": "balance",
          "remaining": "data.available_balance", "unit": "{baseURL.unit}" },
        { "id": "voucher", "name": "Vouchers", "kind": "balance",
          "remaining": "data.voucher_balance", "unit": "{baseURL.unit}" },
        { "id": "cash", "name": "Cash", "kind": "balance",
          "remaining": "data.cash_balance", "unit": "{baseURL.unit}" }
      ],
      "primary": "balance"
    }
    """
}
