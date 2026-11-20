import Foundation

extension DeclarativeProviders {
    /// LiteLLM proxy: what the virtual key spent (USD) against its `max_budget`, and when the
    /// budget window resets. The proxy is the user's own, so the base URL is theirs (`http://localhost`
    /// works). Without `?key=`, `/key/info` describes the key in the Authorization header, so the key
    /// never goes into the URL. `max_budget` null means no budget: spend without a percentage.
    ///
    /// API reference, read 2026-11-19: https://docs.litellm.ai/docs/proxy/users and the `info_key_fn` docstring in litellm/proxy/management_endpoints/key_management_endpoints.py (main)
    static let litellm = """
    {
      "id": "litellm",
      "name": "LiteLLM proxy", "tint": "#14B8A6",
      "stability": "unverified",
      "summary": "Key spend against its budget, with reset (self-hosted)",
      "source": "LiteLLM proxy `GET /key/info`",
      "documentation": "https://docs.litellm.ai/docs/proxy/users",
      "glyph": "server.rack",
      "keyLabel": "LiteLLM virtual key",
      "keyPlaceholder": "sk-…",
      "keyHelpURL": "https://docs.litellm.ai/docs/proxy/virtual_keys",
      "keyAdvice": "Paste the virtual key whose spend you want to see. Don't use the master key: it can manage the whole proxy.",
      "customBaseURL": true,
      "url": "{baseURL}/key/info",
      "headers": { "Authorization": "Bearer {key}" },
      "readings": [
        { "id": "spend", "name": "Key spend", "kind": "spend",
          "amount": "info.spend", "budget": "info.max_budget", "unit": "USD", "period": "budget period",
          "reset": "info.budget_reset_at", "resetFormat": "iso8601" }
      ]
    }
    """
}
