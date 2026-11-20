import Foundation

extension DeclarativeProviders {
    /// Vercel AI Gateway credits: the team's balance and lifetime spend in USD (decimal strings),
    /// and, when the team has a Token Pass, what is left of it and when it resets. `token_pass` is
    /// null without a pass and its `remaining` is null when the gateway can't read it; both leave
    /// the pass reading out. Listed first so that, when present, the pass is the primary.
    ///
    /// API reference, read 2026-11-19: https://vercel.com/docs/ai-gateway/sdks-and-apis/rest-api#check-credit-balance
    static let vercelAIGateway = """
    {
      "id": "vercel-ai-gateway",
      "name": "Vercel AI Gateway", "tint": "#F5F5F5",
      "stability": "unverified",
      "summary": "Credit balance, Token Pass and lifetime spend (USD)",
      "source": "AI Gateway API `GET /v1/credits`",
      "documentation": "https://vercel.com/docs/ai-gateway/sdks-and-apis/rest-api",
      "glyph": "triangle",
      "keyLabel": "AI Gateway API key",
      "keyHelpURL": "https://vercel.com/docs/ai-gateway/authentication-and-byok",
      "keyAdvice": "Use an AI Gateway API key, not a Vercel account token. AI Gateway has no read-only key.",
      "url": "https://ai-gateway.vercel.sh/v1/credits",
      "headers": { "Authorization": "Bearer {key}" },
      "readings": [
        { "id": "token_pass", "name": "Token Pass", "kind": "balance", "optional": true,
          "remaining": "token_pass.remaining", "unit": "USD", "reset": "token_pass.resets_at", "resetFormat": "iso8601" },
        { "id": "balance", "name": "Credit balance", "kind": "balance",
          "remaining": "balance", "unit": "USD" },
        { "id": "total_used", "name": "Spent to date", "kind": "spend",
          "amount": "total_used", "unit": "USD", "period": "to date" }
      ]
    }
    """
}
