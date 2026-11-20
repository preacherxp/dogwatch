import Foundation

extension DeclarativeProviders {
    /// Lovable workspace credits left (subscriptions, top-ups, commitments and bonuses).
    ///
    /// API reference, read 2026-11-19:
    /// https://docs.lovable.dev/api-reference/flagged/credits/get-available-credits
    /// `GET https://api.lovable.dev/v1/workspaces/{workspace_id}/credits/balance` with the
    /// `Lovable-API-Key` header and `Lovable-Version: 2026-09-11`, answered with
    /// `{"available_credits": "124.456789123"}` (an exact decimal string). Business plan or higher
    /// only (other plans get HTTP 402); the key needs the `workspaces:read` scope and is bound to
    /// one workspace. Daily free credits and spending limits are not included.
    static let lovable = """
    {
      "id": "lovable",
      "name": "Lovable", "tint": "#F43F5E",
      "stability": "unverified",
      "category": "subscription",
      "summary": "Workspace credits left (Business plan or higher)",
      "source": "Lovable API `GET /v1/workspaces/{id}/credits/balance`",
      "documentation": "https://docs.lovable.dev/api-reference/flagged/credits/get-available-credits",
      "glyph": "heart.circle",
      "keyLabel": "Lovable API key",
      "keyHelpURL": "https://lovable.dev/settings/api-keys",
      "url": "https://api.lovable.dev/v1/workspaces/{field:workspace}/credits/balance",
      "headers": { "Lovable-API-Key": "{key}", "Lovable-Version": "2026-09-11" },
      "fields": [
        { "id": "workspace", "label": "Workspace ID", "placeholder": "workspace id",
          "help": "The workspace your API key belongs to. Create the key with only the workspaces:read scope." }
      ],
      "readings": [
        { "id": "credits", "name": "Credits", "kind": "balance", "remaining": "available_credits", "unit": "credits" }
      ],
      "refreshMinutes": 15
    }
    """
}
