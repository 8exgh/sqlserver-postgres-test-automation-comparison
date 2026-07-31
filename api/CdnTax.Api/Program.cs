using CdnTax.Api.Configuration;
using CdnTax.Api.Data;
using CdnTax.Api.Endpoints;
using DbParity.Core;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

// The feature flag. Anything unrecognised is fatal rather than defaulted: in a
// project whose whole purpose is comparing two engines, a typo'd
// Database__Provider=postgress silently serving SQL Server would be the worst
// possible failure mode.
var providerName = builder.Configuration["Database:Provider"] ?? nameof(DatabaseProvider.SqlServer);
if (!Enum.TryParse<DatabaseProvider>(providerName, ignoreCase: true, out var provider))
{
    throw new InvalidOperationException(
        $"Database:Provider was '{providerName}'. Expected one of: " +
        string.Join(", ", Enum.GetNames<DatabaseProvider>()) + ".");
}

builder.Services.AddSingleton(new DatabaseOptions(provider));
builder.Services.AddProblemDetails();

builder.Services.AddDbContext<CdnTaxContext>(options =>
{
    // Configuration wins if present, so the API is deployable without the repo
    // checkout. Otherwise fall back to TargetConfig, which resolves credentials the
    // same way the parity suite and the bash scripts do (real env var -> repo-root
    // .env -> the default docker-compose declares). Someone who already has the
    // containers running needs no configuration at all.
    switch (provider)
    {
        case DatabaseProvider.Postgres:
            options.UseNpgsql(builder.Configuration.GetConnectionString("Postgres")
                              ?? TargetConfig.PostgresConnectionString);
            break;

        case DatabaseProvider.SqlServer:
        default:
            options.UseSqlServer(builder.Configuration.GetConnectionString("SqlServer")
                                 ?? TargetConfig.SqlServerConnectionString);
            break;
    }

    if (builder.Configuration.GetValue("Database:LogSql", false))
    {
        // The point of the exercise: read the SQL each provider actually emits.
        options.EnableSensitiveDataLogging().LogTo(Console.WriteLine, LogLevel.Information);
    }
});

var app = builder.Build();

app.UseExceptionHandler();
app.UseStatusCodePages();

app.MapHealthEndpoint();
app.MapClientEndpoints();
app.MapLookupEndpoints();

app.Logger.LogInformation("CdnTax.Api starting against {Provider}", provider);

app.Run();
