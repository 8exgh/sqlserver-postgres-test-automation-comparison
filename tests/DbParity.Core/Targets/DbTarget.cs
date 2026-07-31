using System.Data;
using System.Data.Common;
using DbParity.Core.Results;

namespace DbParity.Core.Targets;

/// <summary>An engine error, in the one form both providers can be compared in.</summary>
/// <param name="Number">
/// The numeric error code. SQL Server reports this directly; the PostgreSQL port
/// carries it as a five-digit SQLSTATE (<c>THROW 50001</c> became
/// <c>ERRCODE '50001'</c>), which parses back to the same integer.
/// </param>
public sealed record DbError(int? Number, string? SqlState, string Message)
{
    public override string ToString() =>
        $"number={Number?.ToString() ?? "-"} sqlstate={SqlState ?? "-"}: {Message}";
}

/// <summary>A procedure argument, named as the SQL Server procedure declares it, without the '@'.</summary>
public sealed record ProcArg(string Name, object? Value, bool IsOutput = false);

/// <summary>
/// A table-valued argument. SQL Server passes these as a table-valued parameter,
/// PostgreSQL as an array of a composite type; the shape is identical, so callers
/// describe it once here and each target renders it.
/// </summary>
public sealed class TableValue
{
    public TableValue(
        string sqlServerType,
        string postgresType,
        IReadOnlyList<(string Name, Type Type)> columns,
        IReadOnlyList<object?[]> rows)
    {
        SqlServerType = sqlServerType;
        PostgresType = postgresType;
        Columns = columns;
        Rows = rows;
    }

    /// <summary>e.g. <c>acct.InvoiceLineType</c>.</summary>
    public string SqlServerType { get; }

    /// <summary>e.g. <c>acct.invoicelinetype</c>.</summary>
    public string PostgresType { get; }

    public IReadOnlyList<(string Name, Type Type)> Columns { get; }
    public IReadOnlyList<object?[]> Rows { get; }
}

/// <summary>
/// One database under comparison. Every engine difference the tests would
/// otherwise have to know about is absorbed here, so a test body reads the same
/// whichever target it is handed.
/// </summary>
public abstract class DbTarget : IDisposable
{
    private bool _disposed;

    /// <summary>"sqlserver" or "postgres" -- used in failure messages.</summary>
    public abstract string Name { get; }

    protected abstract DbConnection Connection { get; }

    /// <summary>The ambient transaction opened by <see cref="BeginRollbackScope"/>, if any.</summary>
    public DbTransaction? CurrentTransaction { get; private set; }

    /// <summary>Runs a statement and materializes every result set it produces.</summary>
    public ResultSet[] Query(string sql)
    {
        using var command = NewCommand(sql);
        using var reader = command.ExecuteReader();

        var sets = new List<ResultSet>();
        do
        {
            // A statement that returned no result set at all (an UPDATE, say) has
            // no fields; recording it as an empty set would misalign the indices
            // of the sets that follow.
            if (reader.FieldCount > 0) sets.Add(ResultSet.Read(reader));
        }
        while (reader.NextResult());

        return sets.ToArray();
    }

    /// <summary>Runs a statement expected to produce exactly one result set.</summary>
    public ResultSet QueryOne(string sql)
    {
        var sets = Query(sql);
        return sets.Length switch
        {
            1 => sets[0],
            0 => throw new InvalidOperationException(
                $"[{Name}] expected one result set, got none. SQL:\n{sql}"),
            _ => throw new InvalidOperationException(
                $"[{Name}] expected one result set, got {sets.Length}. SQL:\n{sql}")
        };
    }

    /// <summary>Convenience for a single-row, single-column scalar.</summary>
    public object? Scalar(string sql)
    {
        using var command = NewCommand(sql);
        return Normalizer.Canonicalize(command.ExecuteScalar());
    }

    public int Execute(string sql)
    {
        using var command = NewCommand(sql);
        return command.ExecuteNonQuery();
    }

    /// <summary>
    /// Runs a statement expected to fail, and reports the engine error rather than
    /// throwing. Returns null when the statement unexpectedly succeeded, which is
    /// itself a finding worth asserting on.
    /// </summary>
    public DbError? TryExecute(string sql)
    {
        try
        {
            Execute(sql);
            return null;
        }
        catch (DbException ex)
        {
            return TranslateError(ex);
        }
    }

    /// <summary>
    /// Opens a transaction that is always rolled back, so mutating tests leave the
    /// fixture byte-identical and test order never matters.
    ///
    /// Deliberately not used for tests that expect an engine error. SQL Server's
    /// procedures set XACT_ABORT around their writes, and a doomed transaction can
    /// neither commit nor roll back to a savepoint -- so error-path assertions run
    /// without an ambient transaction and verify afterwards that nothing was
    /// written, which is also how db/sqlserver/099_verify.sql exercises them.
    /// </summary>
    public IDisposable BeginRollbackScope()
    {
        if (CurrentTransaction is not null)
        {
            throw new InvalidOperationException($"[{Name}] a rollback scope is already open.");
        }

        CurrentTransaction = Connection.BeginTransaction();
        return new RollbackScope(this);
    }

    /// <summary>
    /// Calls a stored procedure and returns every result set it produces, in order.
    /// Arguments are named as the SQL Server procedure declares them (no '@'); the
    /// PostgreSQL target maps them onto the port's <c>par_</c> convention.
    /// </summary>
    public abstract ResultSet[] CallProcedure(string schema, string name, params ProcArg[] args);

    /// <summary>As <see cref="CallProcedure"/>, but reports an engine error instead of throwing.</summary>
    public DbError? TryCallProcedure(string schema, string name, params ProcArg[] args)
    {
        try
        {
            CallProcedure(schema, name, args);
            return null;
        }
        catch (DbException ex)
        {
            return TranslateError(ex);
        }
    }

    /// <summary>Output-parameter values from the most recent <see cref="CallProcedure"/>.</summary>
    public IReadOnlyDictionary<string, object?> LastOutputValues { get; protected set; } =
        new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);

    protected abstract DbError TranslateError(DbException exception);

    protected DbCommand NewCommand(string sql)
    {
        var command = Connection.CreateCommand();
        command.CommandText = sql;
        command.CommandType = CommandType.Text;
        command.Transaction = CurrentTransaction;
        return command;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        CurrentTransaction?.Dispose();
        Connection.Dispose();
        GC.SuppressFinalize(this);
    }

    private sealed class RollbackScope : IDisposable
    {
        private readonly DbTarget _target;
        private bool _closed;

        public RollbackScope(DbTarget target) => _target = target;

        public void Dispose()
        {
            if (_closed) return;
            _closed = true;

            var transaction = _target.CurrentTransaction;
            _target.CurrentTransaction = null;
            if (transaction is null) return;

            try
            {
                transaction.Rollback();
            }
            catch (DbException)
            {
                // A transaction the engine already aborted cannot be rolled back
                // again. The effect wanted -- no committed changes -- has happened
                // either way, so this is not a failure worth masking a real one with.
            }
            finally
            {
                transaction.Dispose();
            }
        }
    }
}
