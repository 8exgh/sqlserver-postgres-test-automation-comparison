using System.Data;
using System.Data.Common;
using DbParity.Core.Results;
using Microsoft.Data.SqlClient;

namespace DbParity.Core.Targets;

/// <summary>
/// The SQL Server side of the comparison.
///
/// The database sets ARITHABORT ON and NUMERIC_ROUNDABORT OFF as database-level
/// defaults (db/sqlserver/001_database_and_schemas.sql), which this connection
/// inherits. That matters: without it, any write to a base table of the indexed
/// view acct.vw_FiscalYearRevenue is rejected outright, and ADO.NET does not set
/// ARITHABORT on its own.
/// </summary>
public sealed class SqlServerTarget : DbTarget
{
    private readonly SqlConnection _connection;

    public SqlServerTarget()
    {
        _connection = new SqlConnection(TargetConfig.SqlServerConnectionString);
        _connection.Open();
    }

    public override string Name => "sqlserver";

    protected override DbConnection Connection => _connection;

    public SqlConnection SqlConnection => _connection;

    public override ResultSet[] CallProcedure(string schema, string name, params ProcArg[] args)
    {
        using var command = _connection.CreateCommand();
        command.CommandText = $"[{schema}].[{name}]";
        command.CommandType = CommandType.StoredProcedure;
        command.Transaction = (SqlTransaction?)CurrentTransaction;

        var outputs = new List<SqlParameter>();

        foreach (var arg in args)
        {
            var parameter = command.CreateParameter();
            parameter.ParameterName = "@" + arg.Name;

            if (arg.Value is TableValue table)
            {
                parameter.SqlDbType = SqlDbType.Structured;
                parameter.TypeName = table.SqlServerType;
                parameter.Value = ToDataTable(table);
            }
            else
            {
                parameter.Value = arg.Value ?? DBNull.Value;
            }

            if (arg.IsOutput)
            {
                parameter.Direction = ParameterDirection.InputOutput;
                // Sized so the provider can marshal a value back; every OUT
                // parameter in this schema is an int, but the guard is cheap.
                if (parameter.Value is DBNull) parameter.DbType = DbType.Int32;
                outputs.Add(parameter);
            }

            command.Parameters.Add(parameter);
        }

        var sets = new List<ResultSet>();
        using (var reader = command.ExecuteReader())
        {
            do
            {
                if (reader.FieldCount > 0) sets.Add(ResultSet.Read(reader));
            }
            while (reader.NextResult());
        }

        // Output parameters are only populated once the reader is closed.
        LastOutputValues = outputs.ToDictionary(
            p => p.ParameterName.TrimStart('@'),
            p => Normalizer.Canonicalize(p.Value),
            StringComparer.OrdinalIgnoreCase);

        return sets.ToArray();
    }

    protected override DbError TranslateError(DbException exception) => exception switch
    {
        SqlException sql => new DbError(sql.Number, null, sql.Message),
        _ => new DbError(null, null, exception.Message)
    };

    /// <summary>
    /// Renders a table-valued argument as the DataTable the structured parameter
    /// expects. Column order is what binds it to the user-defined table type, so
    /// the caller's order is preserved exactly.
    /// </summary>
    private static DataTable ToDataTable(TableValue table)
    {
        var dataTable = new DataTable();
        foreach (var (columnName, columnType) in table.Columns)
        {
            dataTable.Columns.Add(columnName, Nullable.GetUnderlyingType(columnType) ?? columnType);
        }

        foreach (var row in table.Rows)
        {
            dataTable.Rows.Add(row.Select(v => v ?? (object)DBNull.Value).ToArray());
        }

        return dataTable;
    }
}
