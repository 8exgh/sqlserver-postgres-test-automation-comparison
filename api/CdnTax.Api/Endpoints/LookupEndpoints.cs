using CdnTax.Api.Configuration;
using CdnTax.Api.Data;
using CdnTax.Api.Dtos;
using Microsoft.EntityFrameworkCore;

namespace CdnTax.Api.Endpoints;

public static class LookupEndpoints
{
    public static IEndpointRouteBuilder MapLookupEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/practitioners", async (CdnTaxContext db, CancellationToken ct) =>
            Results.Ok(await db.Practitioners
                .AsNoTracking()
                .OrderBy(p => p.PractitionerId)
                .Select(p => new PractitionerResponse(
                    p.PractitionerId, p.FullName, p.Designation, p.Email, p.IsPartner, p.IsActive))
                .ToListAsync(ct)));

        app.MapGet("/api/provinces", async (CdnTaxContext db, CancellationToken ct) =>
        {
            var provinces = await db.Provinces.AsNoTracking().OrderBy(p => p.SortOrder).ToListAsync(ct);
            return Results.Ok(provinces.Select(p => new ProvinceResponse(
                p.ProvinceCode.Trim(), p.ProvinceName, p.IsTerritory, p.SortOrder)));
        });

        app.MapGet("/api/tax-years", async (CdnTaxContext db, CancellationToken ct) =>
            Results.Ok(await db.TaxYears
                .AsNoTracking()
                .OrderByDescending(t => t.Year)
                .Select(t => new TaxYearResponse(
                    t.Year, t.T1FilingDeadline, t.SelfEmployedDeadline, t.RrspDeadline,
                    t.InstallmentThreshold, t.IsLocked))
                .ToListAsync(ct)));

        return app;
    }

    public static IEndpointRouteBuilder MapHealthEndpoint(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/health", async (CdnTaxContext db, DatabaseOptions database, CancellationToken ct) =>
        {
            var connection = db.Database.GetDbConnection();
            var canConnect = await db.Database.CanConnectAsync(ct);
            var count = canConnect ? await db.Clients.CountAsync(ct) : -1;

            // DataSource and Database come from the connection, never the raw string -
            // that would put the password in the response body.
            return Results.Ok(new HealthResponse(
                database.Provider.ToString(), connection.DataSource, connection.Database, canConnect, count));
        });

        return app;
    }
}
