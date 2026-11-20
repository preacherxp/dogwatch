import Foundation

extension DeclarativeProviders {
    /// DeepSeek prepaid balance, one reading per currency the account holds (CNY, USD).
    /// `total_balance` is a decimal string that already includes granted and topped-up balance.
    ///
    /// API reference, read 2026-11-19: https://api-docs.deepseek.com/api/get-user-balance/
    static let deepseek = """
    {
      "id": "deepseek",
      "name": "DeepSeek", "tint": "#4D6BFE",
      "stability": "unverified",
      "summary": "Prepaid balance (CNY or USD)",
      "source": "DeepSeek API `GET /user/balance`",
      "documentation": "https://api-docs.deepseek.com/api/get-user-balance/",
      "glyph": "fish",
      "keyPlaceholder": "sk-…",
      "keyHelpURL": "https://platform.deepseek.com/api_keys",
      "keyAdvice": "DeepSeek has no read-only key; any API key can read the balance.",
      "url": "https://api.deepseek.com/user/balance",
      "headers": { "Authorization": "Bearer {key}" },
      "readings": [
        { "id": "balance_cny", "name": "Balance (CNY)", "kind": "balance", "optional": true,
          "remaining": "balance_infos[currency=CNY].total_balance", "unit": "CNY" },
        { "id": "balance_usd", "name": "Balance (USD)", "kind": "balance", "optional": true,
          "remaining": "balance_infos[currency=USD].total_balance", "unit": "USD" }
      ]
    }
    """
}
