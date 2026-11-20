import Foundation

extension DeclarativeProviders {
    /// Poe point balance (plan and add-on points), an integer count of points.
    ///
    /// API reference, read 2026-11-19: https://creator.poe.com/api-reference/getCurrentBalance
    static let poe = """
    {
      "id": "poe",
      "name": "Poe", "tint": "#7C5CFF",
      "stability": "unverified",
      "summary": "Point balance",
      "source": "Poe API `GET /usage/current_balance`",
      "documentation": "https://creator.poe.com/api-reference/getCurrentBalance",
      "glyph": "bubble.left.and.bubble.right",
      "keyHelpURL": "https://creator.poe.com/docs/resources/usage-api",
      "keyAdvice": "Poe has no read-only key; any Poe API key can read the balance.",
      "url": "https://api.poe.com/usage/current_balance",
      "headers": { "Authorization": "Bearer {key}" },
      "readings": [
        { "id": "points", "name": "Points", "kind": "balance",
          "remaining": "current_point_balance", "unit": "points" }
      ]
    }
    """
}
