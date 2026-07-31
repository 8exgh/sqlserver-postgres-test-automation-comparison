namespace CdnTax.Api.Dtos;

public sealed record EngagementResponse(
    int EngagementId,
    int ClientId,
    short TaxYear,
    string ServiceType,
    int PractitionerId,
    string? PractitionerName,
    string Status,
    decimal FeeQuoted,
    decimal? FeeBilled,
    DateOnly StartedOn,
    DateOnly? CompletedOn);

public sealed record PractitionerResponse(
    int PractitionerId,
    string FullName,
    string? Designation,
    string Email,
    bool IsPartner,
    bool IsActive);

public sealed record ProvinceResponse(
    string ProvinceCode,
    string ProvinceName,
    bool IsTerritory,
    byte SortOrder);

public sealed record TaxYearResponse(
    short TaxYear,
    DateOnly T1FilingDeadline,
    DateOnly SelfEmployedDeadline,
    DateOnly RrspDeadline,
    decimal InstallmentThreshold,
    bool IsLocked);

/// <summary>
/// What <c>GET /api/health</c> returns. Reporting the provider and the row count
/// side by side is the cheapest way to confirm the flag actually switched engines -
/// the counts should match, the provider should not.
/// </summary>
public sealed record HealthResponse(
    string Provider,
    string DataSource,
    string Database,
    bool CanConnect,
    int ClientCount);
