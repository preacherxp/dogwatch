import Foundation

/// Namespace for built-in declarative definitions. Each one lives in its own file,
/// `Providers/Declarative/<Name>Definition.swift`, as an extension with one static JSON string,
/// and is added to `ProviderRegistry.builtIn` with one line:
///
/// ```swift
/// DeclarativeProvider(definition: DeclarativeProviders.novita),
/// ```
///
/// The JSON is exactly what a user would put under `customProviders` in `config.json`, plus the
/// keys only built-ins use: `stability`, `summary`, `source`, `documentation`, `glyph`,
/// `keyHelpURL`, `keyWarning`, `baseURLs` and `fields`. See docs/ADDING-A-PROVIDER.md.
enum DeclarativeProviders {}
