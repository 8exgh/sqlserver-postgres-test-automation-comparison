using DbParity.Core.Fixture;
using DbParity.Core.Targets;
using Xunit;

// Every test in this assembly talks to one of two shared connections and several
// mutate inside rollback scopes. Running them in parallel would interleave those
// transactions on the same connection, so the suite is serial by construction.
// It is IO-bound against two containers either way.
[assembly: CollectionBehavior(DisableTestParallelization = true)]

namespace DbParity.Tests;

/// <summary>
/// Holds the two open targets for the whole run, and guarantees the fixture data
/// is in place before any test executes.
/// </summary>
public sealed class ParityFixture : IDisposable
{
    public ParityFixture()
    {
        try
        {
            SqlServer = new SqlServerTarget();
        }
        catch (Exception ex)
        {
            throw new InvalidOperationException(
                "Could not connect to SQL Server. Start it and apply the schema with " +
                "scripts/apply-sqlserver.sh.\n" + ex.Message, ex);
        }

        try
        {
            Postgres = new PostgresTarget();
        }
        catch (Exception ex)
        {
            SqlServer.Dispose();
            throw new InvalidOperationException(
                "Could not connect to PostgreSQL. Start it and apply the port with " +
                "scripts/apply-postgres.sh.\n" + ex.Message, ex);
        }

        Replication = Replicate();
    }

    public SqlServerTarget SqlServer { get; }

    public PostgresTarget Postgres { get; }

    /// <summary>Per-table row counts confirmed identical on both engines.</summary>
    public ReplicationReport? Replication { get; }

    /// <summary>
    /// Brings PostgreSQL's sample data up to date with SQL Server's before any test
    /// runs, and fails the whole session if a single table lands short. Comparing
    /// two databases that were never given the same input would produce failures
    /// that say nothing about the port.
    ///
    /// Set DBPARITY_SKIP_REPLICATION=1 to reuse the data already loaded -- useful
    /// when iterating on a single case, and unsafe for a real run.
    /// </summary>
    private ReplicationReport? Replicate()
    {
        if (Environment.GetEnvironmentVariable("DBPARITY_SKIP_REPLICATION") == "1") return null;

        var replicator = new FixtureReplicator(SqlServer.SqlConnection, Postgres.NpgsqlConnection);
        return replicator.Run();
    }

    public void Dispose()
    {
        SqlServer.Dispose();
        Postgres.Dispose();
    }
}

/// <summary>
/// Single collection for the whole assembly, so the two connections are opened
/// once and the replication gate runs once.
/// </summary>
[CollectionDefinition(Name)]
public sealed class ParityCollection : ICollectionFixture<ParityFixture>
{
    public const string Name = "db-parity";
}
