using System.Text.RegularExpressions;
using CdnTax.Api.Entities;

namespace CdnTax.Api.Dtos;

public sealed record ClientResponse(
    int ClientId,
    string ClientCode,
    string ClientType,
    string DisplayName,
    string? FirstName,
    string? LastName,
    DateOnly? DateOfBirth,
    string? Sin,
    string? MaritalStatus,
    string? LegalName,
    DateOnly? IncorporationDate,
    string? BusinessNumber,
    byte? FiscalYearEndMonth,
    string ProvinceCode,
    DateOnly OnboardedDate,
    bool IsActive,
    DateTime CreatedAt,
    DateTime? UpdatedAt,
    long RowVersion)
{
    /// <summary>
    /// CHAR(n) columns come back space-padded from SQL Server and unpadded from
    /// PostgreSQL. Trimming here is what keeps the two engines' responses byte
    /// identical, which is the whole point of the exercise.
    /// </summary>
    public static ClientResponse From(Client c) => new(
        c.ClientId,
        c.ClientCode,
        c.ClientType.Trim(),
        c.DisplayName,
        c.FirstName,
        c.LastName,
        c.DateOfBirth,
        c.Sin?.Trim(),
        c.MaritalStatus,
        c.LegalName,
        c.IncorporationDate,
        c.BusinessNumber?.Trim(),
        c.FiscalYearEndMonth,
        c.ProvinceCode.Trim(),
        c.OnboardedDate,
        c.IsActive,
        c.CreatedAt,
        c.UpdatedAt,
        c.RowVersion);
}

public sealed record CreateClientRequest(
    string ClientCode,
    string ClientType,
    string? FirstName,
    string? LastName,
    DateOnly? DateOfBirth,
    string? Sin,
    string? MaritalStatus,
    string? LegalName,
    DateOnly? IncorporationDate,
    string? BusinessNumber,
    byte? FiscalYearEndMonth,
    string ProvinceCode,
    DateOnly OnboardedDate,
    bool IsActive = true);

/// <summary>
/// <paramref name="RowVersion"/> is the token the caller last read. A mismatch
/// means someone else changed the row and the update is rejected with 409.
/// </summary>
public sealed record UpdateClientRequest(
    string ClientCode,
    string ClientType,
    string? FirstName,
    string? LastName,
    DateOnly? DateOfBirth,
    string? Sin,
    string? MaritalStatus,
    string? LegalName,
    DateOnly? IncorporationDate,
    string? BusinessNumber,
    byte? FiscalYearEndMonth,
    string ProvinceCode,
    DateOnly OnboardedDate,
    bool IsActive,
    long RowVersion);

/// <summary>
/// Front-loads the table's CHECK constraints. Both engines enforce these anyway,
/// but they report violations as opaque, differently-shaped driver errors -
/// CK_Client_TypeShape in particular says nothing about which field was wrong.
/// Validating here turns that into a 400 with a field-level message, identically
/// on both providers.
/// </summary>
public static partial class ClientValidation
{
    [GeneratedRegex(@"^\d{9}$")]
    private static partial Regex NineDigits();

    private static readonly string[] MaritalStatuses =
        ["Single", "Married", "Common-law", "Separated", "Divorced", "Widowed"];

    public static Dictionary<string, string[]> Validate(
        string clientCode,
        string clientType,
        string? firstName,
        string? lastName,
        DateOnly? dateOfBirth,
        string? sin,
        string? maritalStatus,
        string? legalName,
        DateOnly? incorporationDate,
        string? businessNumber,
        byte? fiscalYearEndMonth,
        string provinceCode)
    {
        var errors = new Dictionary<string, List<string>>();

        void Fail(string field, string message)
        {
            if (!errors.TryGetValue(field, out var list)) errors[field] = list = [];
            list.Add(message);
        }

        if (string.IsNullOrWhiteSpace(clientCode) || clientCode.Length > 20)
            Fail(nameof(clientCode), "ClientCode is required and must be 20 characters or fewer.");

        if (string.IsNullOrWhiteSpace(provinceCode) || provinceCode.Trim().Length != 2)
            Fail(nameof(provinceCode), "ProvinceCode must be a 2-letter code.");

        var type = clientType?.Trim().ToUpperInvariant();
        if (type is not ("I" or "C"))
        {
            // Nothing below is meaningful without knowing which shape applies.
            Fail(nameof(clientType), "ClientType must be 'I' (individual) or 'C' (corporation).");
            return errors.ToDictionary(e => e.Key, e => e.Value.ToArray());
        }

        if (sin is not null && !NineDigits().IsMatch(sin.Trim()))
            Fail(nameof(sin), "SIN must be exactly 9 digits.");

        if (businessNumber is not null && !NineDigits().IsMatch(businessNumber.Trim()))
            Fail(nameof(businessNumber), "BusinessNumber must be exactly 9 digits.");

        if (maritalStatus is not null && !MaritalStatuses.Contains(maritalStatus))
            Fail(nameof(maritalStatus), $"MaritalStatus must be one of: {string.Join(", ", MaritalStatuses)}.");

        // CK_Client_TypeShape: each type requires its own fields and forbids the other's.
        if (type == "I")
        {
            if (string.IsNullOrWhiteSpace(firstName)) Fail(nameof(firstName), "FirstName is required for an individual.");
            if (string.IsNullOrWhiteSpace(lastName)) Fail(nameof(lastName), "LastName is required for an individual.");
            if (dateOfBirth is null) Fail(nameof(dateOfBirth), "DateOfBirth is required for an individual.");

            if (legalName is not null) Fail(nameof(legalName), "LegalName must be null for an individual.");
            if (incorporationDate is not null) Fail(nameof(incorporationDate), "IncorporationDate must be null for an individual.");
            if (businessNumber is not null) Fail(nameof(businessNumber), "BusinessNumber must be null for an individual.");
            if (fiscalYearEndMonth is not null) Fail(nameof(fiscalYearEndMonth), "FiscalYearEndMonth must be null for an individual.");
        }
        else
        {
            if (string.IsNullOrWhiteSpace(legalName)) Fail(nameof(legalName), "LegalName is required for a corporation.");
            if (incorporationDate is null) Fail(nameof(incorporationDate), "IncorporationDate is required for a corporation.");
            if (fiscalYearEndMonth is null) Fail(nameof(fiscalYearEndMonth), "FiscalYearEndMonth is required for a corporation.");
            else if (fiscalYearEndMonth is < 1 or > 12) Fail(nameof(fiscalYearEndMonth), "FiscalYearEndMonth must be between 1 and 12.");

            if (firstName is not null) Fail(nameof(firstName), "FirstName must be null for a corporation.");
            if (lastName is not null) Fail(nameof(lastName), "LastName must be null for a corporation.");
            if (dateOfBirth is not null) Fail(nameof(dateOfBirth), "DateOfBirth must be null for a corporation.");
            if (sin is not null) Fail(nameof(sin), "SIN must be null for a corporation.");
            if (maritalStatus is not null) Fail(nameof(maritalStatus), "MaritalStatus must be null for a corporation.");
        }

        return errors.ToDictionary(e => e.Key, e => e.Value.ToArray());
    }
}
