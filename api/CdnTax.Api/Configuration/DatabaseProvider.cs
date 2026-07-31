namespace CdnTax.Api.Configuration;

/// <summary>
/// The feature flag. Bound from configuration key <c>Database:Provider</c>, so any
/// of these select PostgreSQL:
/// <code>
///   dotnet run -- --Database:Provider=Postgres
///   Database__Provider=Postgres dotnet run
///   "Database": { "Provider": "Postgres" }   in appsettings.json
/// </code>
/// SQL Server is the default because it is the source of truth in this repository;
/// PostgreSQL is the port under test.
/// </summary>
public enum DatabaseProvider
{
    SqlServer = 0,
    Postgres = 1,
}
