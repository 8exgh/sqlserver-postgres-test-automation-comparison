namespace CdnTax.Api.Entities;

/// <summary>client.Practitioner - staff at the practice who own engagements.</summary>
public sealed class Practitioner
{
    public int PractitionerId { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string? Designation { get; set; }
    public string Email { get; set; } = string.Empty;
    public bool IsPartner { get; set; }
    public bool IsActive { get; set; } = true;
}
