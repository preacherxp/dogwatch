import Foundation

extension DeclarativeProviders {
    /// Kilo Code credit balance (Kilo Pass credits and top-ups), in dollars.
    ///
    /// Read 2026-11-19:
    /// - https://kilo.ai/docs/gateway/authentication: API keys are bearer tokens tied to the Kilo
    ///   account (`KILO_API_KEY`).
    /// - https://kilo.ai/docs/gateway/usage-and-billing: "$1 of purchased credits funds $1 of usage";
    ///   no rate windows on paid models.
    /// - The endpoint isn't in Kilo's docs. It is what Kilo's own CLI reads for `kilo profile`
    ///   (https://github.com/Kilo-Org/kilocode, packages/kilo-gateway/src/api/profile.ts):
    ///   `GET https://api.kilo.ai/api/profile/balance` with `Authorization: Bearer <token>`,
    ///   answered with `{balance}` and printed as `$balance`. An organisation's balance needs an
    ///   `X-KiloCode-OrganizationId` header, which a definition can't fill from a setting, so only
    ///   the personal balance is read.
    static let kilo = """
    {
      "id": "kilo",
      "name": "Kilo Code", "tint": "#F2C94C",
      "stability": "unverified",
      "category": "subscription",
      "summary": "Kilo credit balance (Kilo Pass and top-ups)",
      "source": "Kilo `GET /api/profile/balance` (what the Kilo CLI reads)",
      "documentation": "https://kilo.ai/docs/gateway/usage-and-billing",
      "glyph": "scalemass",
      "keyLabel": "Kilo API key",
      "keyHelpURL": "https://kilo.ai/docs/getting-started/setup-authentication#kilo-gateway-api-key",
      "keyWarning": "A Kilo API key can also spend your Kilo balance on model requests.",
      "url": "https://api.kilo.ai/api/profile/balance",
      "headers": { "Authorization": "Bearer {key}" },
      "readings": [
        { "id": "balance", "name": "Balance", "kind": "balance", "remaining": "balance", "unit": "USD" }
      ],
      "refreshMinutes": 15
    }
    """
}
