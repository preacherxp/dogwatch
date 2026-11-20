import Foundation

extension DeclarativeProviders {
    /// ElevenLabs credits used of this period's limit, with the next reset (Unix seconds). The
    /// answer calls them characters; ElevenLabs bills them as credits. A limit of 0 shows no reading.
    ///
    /// API reference, read 2026-11-19: https://elevenlabs.io/docs/api-reference/user/subscription/get
    static let elevenlabs = """
    {
      "id": "elevenlabs",
      "name": "ElevenLabs", "tint": "#F97316",
      "stability": "unverified",
      "summary": "Credits used of the plan's limit, with reset",
      "source": "ElevenLabs API `GET /v1/user/subscription`",
      "documentation": "https://elevenlabs.io/docs/api-reference/user/subscription/get",
      "glyph": "waveform",
      "keyHelpURL": "https://elevenlabs.io/docs/api-reference/authentication",
      "keyAdvice": "ElevenLabs keys can be restricted to certain endpoints. A key that can only read user information is enough.",
      "baseURLs": [
        { "label": "Default", "url": "https://api.elevenlabs.io" },
        { "label": "United States", "url": "https://api.us.elevenlabs.io" },
        { "label": "EU residency", "url": "https://api.eu.residency.elevenlabs.io" },
        { "label": "India residency", "url": "https://api.in.residency.elevenlabs.io" },
        { "label": "Singapore residency", "url": "https://api.sg.residency.elevenlabs.io" }
      ],
      "url": "{baseURL}/v1/user/subscription",
      "headers": { "xi-api-key": "{key}" },
      "readings": [
        { "id": "credits", "name": "Credits", "kind": "window",
          "used": "character_count", "limit": "character_limit", "unit": "credits", "period": "this period",
          "reset": "next_character_count_reset_unix", "resetFormat": "unixSeconds" }
      ]
    }
    """
}
