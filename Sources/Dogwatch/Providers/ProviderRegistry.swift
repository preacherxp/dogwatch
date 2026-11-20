import Foundation

/// Every built-in provider, one per line, sorted by id. Adding a provider adds one line here and
/// nothing else outside its own files. A built-in declarative provider is a line such as
/// `DeclarativeProvider(definition: DeclarativeProviders.novita),` in the same list.
enum ProviderRegistry {
    static let builtIn: [any UsageProvider] = [
        DeclarativeProvider(definition: DeclarativeProviders.aimlapi),
        AnthropicAPIProvider(),
        AntigravityProvider(),
        ClaudeProvider(),
        ClineProvider(),
        CodexProvider(),
        CopilotProvider(),
        CursorProvider(),
        DeepgramProvider(),
        DeepInfraProvider(),
        DeclarativeProvider(definition: DeclarativeProviders.deepseek),
        DevinProvider(),
        DeclarativeProvider(definition: DeclarativeProviders.elevenlabs),
        FactoryProvider(),
        DeclarativeProvider(definition: DeclarativeProviders.fal),
        FireworksProvider(),
        GeminiCLIProvider(),
        GrokProvider(),
        HuggingFaceProvider(),
        DeclarativeProvider(definition: DeclarativeProviders.hyperbolic),
        JetBrainsProvider(),
        DeclarativeProvider(definition: DeclarativeProviders.kilo),
        KimiProvider(),
        KiroProvider(),
        DeclarativeProvider(definition: DeclarativeProviders.litellm),
        DeclarativeProvider(definition: DeclarativeProviders.lovable),
        MiniMaxProvider(),
        MistralAPIProvider(),
        DeclarativeProvider(definition: DeclarativeProviders.moonshot),
        DeclarativeProvider(definition: DeclarativeProviders.novita),
        DeclarativeProvider(definition: DeclarativeProviders.ollamaCloud),
        OpenAIProvider(),
        OpenCodeGoProvider(),
        OpenRouterProvider(),
        DeclarativeProvider(definition: DeclarativeProviders.poe),
        DeclarativeProvider(definition: DeclarativeProviders.stability),
        TogetherProvider(),
        V0Provider(),
        DeclarativeProvider(definition: DeclarativeProviders.venice),
        DeclarativeProvider(definition: DeclarativeProviders.vercelAIGateway),
        ZaiProvider(),
    ]

    /// The providers new users see switched on, in this order. Everything else starts off.
    static let defaultEnabled: [ProviderID] = [.codex, .claude, .grok]
}
