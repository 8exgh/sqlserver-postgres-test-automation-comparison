namespace CdnTax.Api.Configuration;

/// <summary>
/// Carries the resolved <see cref="DatabaseProvider"/> through DI. A reference type
/// because the container cannot register a bare enum value.
/// </summary>
/// <param name="Provider">The engine this process was started against.</param>
public sealed record DatabaseOptions(DatabaseProvider Provider);
