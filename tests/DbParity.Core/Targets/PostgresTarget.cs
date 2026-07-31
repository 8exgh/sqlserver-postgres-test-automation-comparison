using System.Data.Common;
using DbParity.Core.Results;
using Npgsql;

namespace DbParity.Core.Targets;

/// <summary>
/// The PostgreSQL side of the comparison.
///
/// Two things differ structurally from SQL Server and are handled here so no test
/// has to know about them:
///
///   Result sets   The port returns them through INOUT refcursor parameters (SCT's
///                 choice, kept because it is the normal PostgreSQL idiom). A cursor
///                 only lives inside a transaction, so CallProcedure opens one if
///                 the caller has not, and fetches before it ends.
///
///   Names         SQL Server's @ClientId is par_clientid here, and output
///                 parameters became INOUT. Callers use the SQL Server spelling.
/// </summary>
public sealed class PostgresTarget : DbTarget
{
    private readonly NpgsqlConnection _connection;
    private readonly Dictionary<string, IReadOnlyList<PgArg>> _signatureCache = new(StringComparer.Ordinal);
    private int _cursorSequence;

    public PostgresTarget()
    {
        _connection = new NpgsqlConnection(TargetConfig.PostgresConnectionString);
        _connection.Open();
    }

    public override string Name => "postgres";

    protected override DbConnection Connection => _connection;

    public NpgsqlConnection NpgsqlConnection => _connection;

    /// <summary>Maps a SQL Server parameter name onto the port's convention: @ClientId -> par_clientid.</summary>
    public static string ParameterName(string sqlServerName) => "par_" + sqlServerName.ToLowerInvariant();

    public override ResultSet[] CallProcedure(string schema, string name, params ProcArg[] args)
    {
        var signature = GetSignature(schema, name);
        var cursorArgs = signature.Where(a => a.IsCursor).ToArray();

        // Cursors do not survive their transaction, so one is required. If the
        // caller already opened a rollback scope we join it; otherwise we open and
        // commit a local one, which leaves the procedure's own writes in place
        // exactly as an unwrapped call on SQL Server would.
        var ownsTransaction = CurrentTransaction is null;
        var transaction = ownsTransaction ? _connection.BeginTransaction() : (NpgsqlTransaction)CurrentTransaction!;

        try
        {
            var cursorNames = cursorArgs
                .Select(_ => $"parity_cur_{Interlocked.Increment(ref _cursorSequence)}")
                .ToArray();

            var outputs = new Dictionary<string, object?>(StringComparer.OrdinalIgnoreCase);

            using (var call = _connection.CreateCommand())
            {
                call.Transaction = transaction;
                call.CommandText = BuildCall(schema, name, args, signature, cursorArgs, cursorNames, call);

                using var reader = call.ExecuteReader();
                // CALL returns a single row carrying the INOUT values. Scalar OUT
                // parameters are read from it; the cursor columns are the names we
                // supplied and are already known.
                var cursorParameterNames = cursorArgs.Select(a => a.Name).ToHashSet(StringComparer.Ordinal);
                if (reader.Read())
                {
                    for (var i = 0; i < reader.FieldCount; i++)
                    {
                        var column = reader.GetName(i);
                        if (cursorParameterNames.Contains(column)) continue;
                        outputs[StripParPrefix(column)] =
                            Normalizer.Canonicalize(reader.IsDBNull(i) ? null : reader.GetValue(i));
                    }
                }
            }

            LastOutputValues = outputs;

            var sets = new List<ResultSet>();
            foreach (var cursorName in cursorNames)
            {
                using var fetch = _connection.CreateCommand();
                fetch.Transaction = transaction;
                fetch.CommandText = $"FETCH ALL IN \"{cursorName}\"";
                using var reader = fetch.ExecuteReader();
                var set = ResultSet.Read(reader);
                // A procedure that opened fewer cursors than it declares leaves the
                // rest unopened; SQL Server simply produces fewer result sets, so an
                // empty, column-less set is dropped to keep the two aligned.
                if (set.Columns.Count > 0) sets.Add(set);
            }

            if (ownsTransaction) transaction.Commit();
            return sets.ToArray();
        }
        catch
        {
            if (ownsTransaction)
            {
                try { transaction.Rollback(); } catch (DbException) { /* already aborted */ }
            }
            throw;
        }
        finally
        {
            if (ownsTransaction) transaction.Dispose();
        }
    }

    protected override DbError TranslateError(DbException exception) => exception switch
    {
        // The port carries SQL Server's THROW numbers as five-digit SQLSTATEs
        // (THROW 50001 -> ERRCODE '50001'), so the two engines compare directly.
        PostgresException pg => new DbError(
            int.TryParse(pg.SqlState, out var number) ? number : null,
            pg.SqlState,
            pg.MessageText),
        _ => new DbError(null, null, exception.Message)
    };

    /// <summary>
    /// Callers write arguments as the SQL Server procedure declares them, so a
    /// BIT parameter arrives as a bool. The port maps BIT onto numeric(1,0), and
    /// PostgreSQL will not coerce boolean to numeric on its own.
    /// </summary>
    private static object Coerce(object? value, string? declaredType = null) => value switch
    {
        null => DBNull.Value,
        bool flag => flag ? 1m : 0m,
        // Callers hand over a DateTime because that is what SQL Server's DATE
        // parameters take; PostgreSQL wants a DateOnly for a date parameter.
        DateTime moment when declaredType == "date" => DateOnly.FromDateTime(moment),
        _ => value
    };

    private static string StripParPrefix(string column) =>
        column.StartsWith("par_", StringComparison.Ordinal) ? column[4..] : column;

    /// <summary>
    /// Builds a CALL in named notation, which lets the caller supply arguments in
    /// any order and leaves the procedure's own DEFAULTs in place for the rest.
    /// </summary>
    private string BuildCall(
        string schema,
        string name,
        IReadOnlyList<ProcArg> args,
        IReadOnlyList<PgArg> signature,
        IReadOnlyList<PgArg> cursorArgs,
        IReadOnlyList<string> cursorNames,
        NpgsqlCommand command)
    {
        var parts = new List<string>();

        for (var i = 0; i < args.Count; i++)
        {
            var arg = args[i];
            var target = ParameterName(arg.Name);

            if (arg.Value is TableValue table)
            {
                parts.Add($"{target} => {BuildCompositeArray(table, i, command)}");
                continue;
            }

            var declared = signature.FirstOrDefault(
                a => string.Equals(a.Name, target, StringComparison.Ordinal));
            if (declared is null)
            {
                throw new InvalidOperationException(
                    $"[postgres] {schema}.{name} has no parameter '{target}' " +
                    $"(from SQL Server's @{arg.Name}). Declared: " +
                    string.Join(", ", signature.Select(a => a.Name)) + ".");
            }

            // Bind with the type the procedure declares rather than letting Npgsql
            // infer it. Inference sends an untyped NULL as 'unknown', which makes
            // overload resolution fail outright, and sends a DateTime as timestamp
            // where the parameter is a date -- PostgreSQL will not narrow that
            // implicitly, so the CALL would not resolve at all.
            var parameter = new NpgsqlParameter($"p{i}", Coerce(arg.Value, declared.Type))
            {
                DataTypeName = declared.Type
            };
            command.Parameters.Add(parameter);
            parts.Add($"{target} => @p{i}");
        }

        for (var i = 0; i < cursorArgs.Count; i++)
        {
            parts.Add($"{cursorArgs[i].Name} => '{cursorNames[i]}'");
        }

        return $"CALL {schema}.{name}({string.Join(", ", parts)})";
    }

    /// <summary>
    /// Renders a table-valued argument as an array of the composite type declared in
    /// db/postgres/001_schemas_and_types.sql. Values stay parameterized -- only the
    /// ROW() scaffolding is generated text -- so nothing here depends on quoting.
    /// </summary>
    private static string BuildCompositeArray(TableValue table, int argIndex, NpgsqlCommand command)
    {
        if (table.Rows.Count == 0) return $"ARRAY[]::{table.PostgresType}[]";

        var rows = new List<string>(table.Rows.Count);
        for (var r = 0; r < table.Rows.Count; r++)
        {
            var fields = new List<string>(table.Columns.Count);
            for (var c = 0; c < table.Columns.Count; c++)
            {
                var placeholder = $"t{argIndex}_{r}_{c}";
                command.Parameters.AddWithValue(placeholder, Coerce(table.Rows[r][c]));
                fields.Add("@" + placeholder);
            }
            rows.Add($"ROW({string.Join(", ", fields)})::{table.PostgresType}");
        }

        return $"ARRAY[{string.Join(", ", rows)}]";
    }

    private IReadOnlyList<PgArg> GetSignature(string schema, string name)
    {
        var key = $"{schema}.{name}";
        if (_signatureCache.TryGetValue(key, out var cached)) return cached;

        const string sql = """
            SELECT p.proargnames::text[]                                       AS names,
                   COALESCE(p.proargmodes::text[], '{}'::text[])               AS modes,
                   ARRAY(SELECT format_type(t, NULL)
                         FROM unnest(COALESCE(p.proallargtypes,
                                              p.proargtypes::oid[])) AS t)     AS types
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = @schema AND p.proname = @name AND p.prokind = 'p'
            """;

        using var command = _connection.CreateCommand();
        command.Transaction = (NpgsqlTransaction?)CurrentTransaction;
        command.CommandText = sql;
        command.Parameters.AddWithValue("schema", schema.ToLowerInvariant());
        command.Parameters.AddWithValue("name", name.ToLowerInvariant());

        using var reader = command.ExecuteReader();
        if (!reader.Read())
        {
            throw new InvalidOperationException(
                $"[postgres] no procedure named {schema}.{name}. " +
                "The port may not have been applied -- run scripts/apply-postgres.sh.");
        }

        var names = reader.GetFieldValue<string[]>(0);
        var modes = reader.GetFieldValue<string[]>(1);
        var types = reader.GetFieldValue<string[]>(2);

        var signature = new List<PgArg>(names.Length);
        for (var i = 0; i < names.Length; i++)
        {
            var mode = i < modes.Length ? modes[i] : "i";
            var type = i < types.Length ? types[i] : "unknown";
            signature.Add(new PgArg(names[i], mode, type));
        }

        _signatureCache[key] = signature;
        return signature;
    }

    /// <param name="Mode">'i' in, 'o' out, 'b' inout, 'v' variadic, 't' table.</param>
    private sealed record PgArg(string Name, string Mode, string Type)
    {
        public bool IsCursor => string.Equals(Type, "refcursor", StringComparison.Ordinal);
    }
}
