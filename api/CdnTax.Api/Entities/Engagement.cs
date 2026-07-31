namespace CdnTax.Api.Entities;

/// <summary>client.Engagement - a unit of billable work for a client in a tax year.</summary>
public sealed class Engagement
{
    public int EngagementId { get; set; }
    public int ClientId { get; set; }
    public short TaxYear { get; set; }
    public string ServiceType { get; set; } = string.Empty;
    public int PractitionerId { get; set; }
    public string Status { get; set; } = string.Empty;
    public decimal FeeQuoted { get; set; }
    public decimal? FeeBilled { get; set; }
    public DateOnly StartedOn { get; set; }
    public DateOnly? CompletedOn { get; set; }

    public Client? Client { get; set; }
    public Practitioner? Practitioner { get; set; }
}
