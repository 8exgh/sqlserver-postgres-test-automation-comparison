namespace CdnTax.Api.Entities;

/// <summary>ref.TaxYear - filing deadlines and the lock flag, keyed by year.</summary>
public sealed class TaxYear
{
    public short Year { get; set; }
    public DateOnly T1FilingDeadline { get; set; }
    public DateOnly SelfEmployedDeadline { get; set; }
    public DateOnly RrspDeadline { get; set; }
    public decimal InstallmentThreshold { get; set; }
    public bool IsLocked { get; set; }
}
