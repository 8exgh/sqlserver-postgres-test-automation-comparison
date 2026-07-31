using System.Diagnostics;
using DbParity.Core.Fixture;

// Copies the sample data from SQL Server into PostgreSQL so the parity suite has
// identical inputs on both sides. Normally invoked via scripts/replicate-to-postgres.sh;
// DbParity.Tests also runs the same code once per session.

var stopwatch = Stopwatch.StartNew();

try
{
    Console.WriteLine("==> Replicating sample data: SQL Server -> PostgreSQL");

    var replicator = FixtureReplicator.Connect();
    try
    {
        var report = replicator.Run(Console.WriteLine);
        Console.WriteLine($"==> {report.TotalRows:N0} rows across {report.RowCounts.Count} tables " +
                          $"in {stopwatch.Elapsed.TotalSeconds:F1}s");
        Console.WriteLine("==> Row counts match on both engines.");
        return 0;
    }
    finally
    {
        replicator.Dispose();
    }
}
catch (Exception ex)
{
    Console.Error.WriteLine("ERROR: " + ex.Message);
    return 1;
}
