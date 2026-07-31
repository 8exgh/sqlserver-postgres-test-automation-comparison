namespace CdnTax.Api.Entities;

/// <summary>ref.Province - the 13 provinces and territories.</summary>
public sealed class Province
{
    public string ProvinceCode { get; set; } = string.Empty;
    public string ProvinceName { get; set; } = string.Empty;
    public bool IsTerritory { get; set; }

    /// <summary>TINYINT on SQL Server, SMALLINT on PostgreSQL - see CdnTaxContext.</summary>
    public byte SortOrder { get; set; }
}
