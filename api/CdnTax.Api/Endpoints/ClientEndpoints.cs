using CdnTax.Api.Data;
using CdnTax.Api.Dtos;
using CdnTax.Api.Entities;
using Microsoft.EntityFrameworkCore;

namespace CdnTax.Api.Endpoints;

public static class ClientEndpoints
{
    public static IEndpointRouteBuilder MapClientEndpoints(this IEndpointRouteBuilder app)
    {
        var group = app.MapGroup("/api/clients");

        group.MapGet("/", GetClients);
        group.MapGet("/{id:int}", GetClient);
        group.MapGet("/{id:int}/engagements", GetEngagements);
        group.MapPost("/", CreateClient);
        group.MapPut("/{id:int}", UpdateClient);
        group.MapDelete("/{id:int}", DeleteClient);

        return app;
    }

    private static async Task<IResult> GetClients(
        CdnTaxContext db,
        string? province,
        bool? active,
        string? type,
        string? search,
        int skip = 0,
        int take = 50,
        CancellationToken cancellationToken = default)
    {
        var query = db.Clients.AsNoTracking();

        // ProvinceCode is CHAR(2): SQL Server pads the stored value, so compare on a
        // padded parameter rather than trimming the column, which would defeat the index.
        if (!string.IsNullOrWhiteSpace(province))
        {
            var code = province.Trim().ToUpperInvariant();
            query = query.Where(c => c.ProvinceCode == code);
        }

        if (active is not null) query = query.Where(c => c.IsActive == active.Value);

        if (!string.IsNullOrWhiteSpace(type))
        {
            var clientType = type.Trim().ToUpperInvariant();
            query = query.Where(c => c.ClientType == clientType);
        }

        if (!string.IsNullOrWhiteSpace(search))
        {
            var pattern = $"%{search.Trim()}%";
            query = query.Where(c => EF.Functions.Like(c.DisplayName, pattern)
                                  || EF.Functions.Like(c.ClientCode, pattern));
        }

        var results = await query
            .OrderBy(c => c.ClientId)
            .Skip(Math.Max(skip, 0))
            .Take(Math.Clamp(take, 1, 200))
            .ToListAsync(cancellationToken);

        return Results.Ok(results.Select(ClientResponse.From));
    }

    private static async Task<IResult> GetClient(int id, CdnTaxContext db, CancellationToken cancellationToken)
    {
        var client = await db.Clients.AsNoTracking().FirstOrDefaultAsync(c => c.ClientId == id, cancellationToken);
        return client is null ? Results.NotFound() : Results.Ok(ClientResponse.From(client));
    }

    private static async Task<IResult> GetEngagements(int id, CdnTaxContext db, CancellationToken cancellationToken)
    {
        if (!await db.Clients.AnyAsync(c => c.ClientId == id, cancellationToken)) return Results.NotFound();

        var engagements = await db.Engagements
            .AsNoTracking()
            .Include(e => e.Practitioner)
            .Where(e => e.ClientId == id)
            .OrderBy(e => e.TaxYear).ThenBy(e => e.ServiceType)
            .ToListAsync(cancellationToken);

        return Results.Ok(engagements.Select(e => new EngagementResponse(
            e.EngagementId, e.ClientId, e.TaxYear, e.ServiceType, e.PractitionerId,
            e.Practitioner?.FullName, e.Status, e.FeeQuoted, e.FeeBilled, e.StartedOn, e.CompletedOn)));
    }

    private static async Task<IResult> CreateClient(
        CreateClientRequest request, CdnTaxContext db, CancellationToken cancellationToken)
    {
        var errors = ClientValidation.Validate(
            request.ClientCode, request.ClientType, request.FirstName, request.LastName,
            request.DateOfBirth, request.Sin, request.MaritalStatus, request.LegalName,
            request.IncorporationDate, request.BusinessNumber, request.FiscalYearEndMonth,
            request.ProvinceCode);

        if (errors.Count > 0) return Results.ValidationProblem(errors);

        var client = new Client
        {
            ClientCode = request.ClientCode.Trim(),
            ClientType = request.ClientType.Trim().ToUpperInvariant(),
            FirstName = request.FirstName,
            LastName = request.LastName,
            DateOfBirth = request.DateOfBirth,
            Sin = request.Sin?.Trim(),
            MaritalStatus = request.MaritalStatus,
            LegalName = request.LegalName,
            IncorporationDate = request.IncorporationDate,
            BusinessNumber = request.BusinessNumber?.Trim(),
            FiscalYearEndMonth = request.FiscalYearEndMonth,
            ProvinceCode = request.ProvinceCode.Trim().ToUpperInvariant(),
            OnboardedDate = request.OnboardedDate,
            IsActive = request.IsActive,
        };

        db.Clients.Add(client);

        var failure = await SaveAsync(db, cancellationToken);
        if (failure is not null) return failure;

        return Results.Created($"/api/clients/{client.ClientId}", ClientResponse.From(client));
    }

    private static async Task<IResult> UpdateClient(
        int id, UpdateClientRequest request, CdnTaxContext db, CancellationToken cancellationToken)
    {
        var errors = ClientValidation.Validate(
            request.ClientCode, request.ClientType, request.FirstName, request.LastName,
            request.DateOfBirth, request.Sin, request.MaritalStatus, request.LegalName,
            request.IncorporationDate, request.BusinessNumber, request.FiscalYearEndMonth,
            request.ProvinceCode);

        if (errors.Count > 0) return Results.ValidationProblem(errors);

        var client = await db.Clients.FirstOrDefaultAsync(c => c.ClientId == id, cancellationToken);
        if (client is null) return Results.NotFound();

        // The token the caller last read, not the one just loaded - that is what makes
        // the UPDATE's WHERE clause fail when someone else has written in between.
        db.Entry(client).Property(c => c.RowVersion).OriginalValue = request.RowVersion;

        client.ClientCode = request.ClientCode.Trim();
        client.ClientType = request.ClientType.Trim().ToUpperInvariant();
        client.FirstName = request.FirstName;
        client.LastName = request.LastName;
        client.DateOfBirth = request.DateOfBirth;
        client.Sin = request.Sin?.Trim();
        client.MaritalStatus = request.MaritalStatus;
        client.LegalName = request.LegalName;
        client.IncorporationDate = request.IncorporationDate;
        client.BusinessNumber = request.BusinessNumber?.Trim();
        client.FiscalYearEndMonth = request.FiscalYearEndMonth;
        client.ProvinceCode = request.ProvinceCode.Trim().ToUpperInvariant();
        client.OnboardedDate = request.OnboardedDate;
        client.IsActive = request.IsActive;
        client.UpdatedAt = CdnTaxContext.UtcNowNaive();

        var failure = await SaveAsync(db, cancellationToken, id);
        if (failure is not null) return failure;

        return Results.Ok(ClientResponse.From(client));
    }

    private static async Task<IResult> DeleteClient(int id, CdnTaxContext db, CancellationToken cancellationToken)
    {
        var client = await db.Clients.FirstOrDefaultAsync(c => c.ClientId == id, cancellationToken);
        if (client is null) return Results.NotFound();

        db.Clients.Remove(client);

        var failure = await SaveAsync(db, cancellationToken, id);
        return failure ?? Results.NoContent();
    }

    /// <summary>
    /// Returns null on success, or the <see cref="IResult"/> to send back. Keeps the
    /// concurrency and constraint handling in one place rather than repeated per verb.
    /// </summary>
    private static async Task<IResult?> SaveAsync(CdnTaxContext db, CancellationToken cancellationToken, int? id = null)
    {
        try
        {
            await db.SaveChangesAsync(cancellationToken);
            return null;
        }
        catch (DbUpdateConcurrencyException)
        {
            db.ChangeTracker.Clear();
            var current = id is null
                ? null
                : await db.Clients.AsNoTracking().FirstOrDefaultAsync(c => c.ClientId == id, cancellationToken);

            return Results.Json(new
            {
                title = "The client was modified by someone else.",
                detail = "The supplied rowVersion no longer matches the stored one. Re-read the client and retry.",
                current = current is null ? null : ClientResponse.From(current),
            }, statusCode: StatusCodes.Status409Conflict);
        }
        catch (DbUpdateException exception)
        {
            var detail = DbErrorTranslator.Detail(exception);
            return DbErrorTranslator.Classify(exception) switch
            {
                DbErrorTranslator.DbFailure.UniqueViolation =>
                    Results.Problem(detail, statusCode: StatusCodes.Status409Conflict, title: "Duplicate value."),
                DbErrorTranslator.DbFailure.ForeignKeyViolation =>
                    Results.Problem(detail, statusCode: StatusCodes.Status400BadRequest, title: "Referenced row does not exist."),
                DbErrorTranslator.DbFailure.CheckViolation =>
                    Results.Problem(detail, statusCode: StatusCodes.Status400BadRequest, title: "Check constraint violated."),
                _ => Results.Problem(detail, statusCode: StatusCodes.Status500InternalServerError, title: "Database error."),
            };
        }
    }
}
