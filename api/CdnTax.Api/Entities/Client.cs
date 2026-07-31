namespace CdnTax.Api.Entities;

/// <summary>
/// client.Client - an individual (T1) or a corporation (T2), discriminated by
/// <see cref="ClientType"/>. The nullable name/date columns are the two shapes:
/// CK_Client_TypeShape requires an individual to carry the personal fields and
/// none of the corporate ones, and vice versa.
/// </summary>
public sealed class Client
{
    public int ClientId { get; set; }

    public string ClientCode { get; set; } = string.Empty;

    /// <summary>'I'ndividual or 'C'orporation. See CK_Client_Type.</summary>
    public string ClientType { get; set; } = string.Empty;

    // Individuals
    public string? FirstName { get; set; }
    public string? LastName { get; set; }
    public DateOnly? DateOfBirth { get; set; }
    public string? Sin { get; set; }
    public string? MaritalStatus { get; set; }

    // Corporations
    public string? LegalName { get; set; }
    public DateOnly? IncorporationDate { get; set; }
    public string? BusinessNumber { get; set; }
    public byte? FiscalYearEndMonth { get; set; }

    // Common
    public string ProvinceCode { get; set; } = string.Empty;
    public DateOnly OnboardedDate { get; set; }
    public bool IsActive { get; set; } = true;

    /// <summary>
    /// Database-computed on both engines - PERSISTED on SQL Server, GENERATED
    /// ALWAYS ... STORED on PostgreSQL. Never written by the application.
    /// </summary>
    public string DisplayName { get; set; } = string.Empty;

    /// <summary>Defaulted by the database on both engines.</summary>
    public DateTime CreatedAt { get; set; }

    public DateTime? UpdatedAt { get; set; }

    /// <summary>
    /// Optimistic concurrency token. Server-maintained on both engines, but by
    /// completely different mechanisms: a native ROWVERSION on SQL Server, and a
    /// sequence driven by trigger client.tr_client_biu on PostgreSQL. See
    /// CdnTaxContext.OnModelCreating for the two mappings.
    /// </summary>
    public long RowVersion { get; set; }

    public Province? Province { get; set; }
    public ICollection<Engagement> Engagements { get; set; } = [];
}
