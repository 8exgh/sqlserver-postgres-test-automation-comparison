using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Npgsql;

namespace CdnTax.Api.Data;

/// <summary>
/// What EF Core does <em>not</em> abstract away.
///
/// A unique-key violation is a unique-key violation on both engines, but it
/// arrives as <see cref="SqlException"/> number 2627/2601 on one and as
/// <see cref="PostgresException"/> SQLSTATE 23505 on the other, with different
/// message text. Anything that wants to answer 409 rather than 500 has to know
/// both vocabularies - so the knowledge is isolated here instead of leaking into
/// every endpoint.
/// </summary>
public static class DbErrorTranslator
{
    public enum DbFailure
    {
        Unknown,
        UniqueViolation,
        ForeignKeyViolation,
        CheckViolation,
    }

    public static DbFailure Classify(DbUpdateException exception) => exception.InnerException switch
    {
        SqlException sql => sql.Number switch
        {
            2627 or 2601 => DbFailure.UniqueViolation,   // PK/unique constraint, unique index
            547 => ConstraintNameSuggestsCheck(sql.Message)
                ? DbFailure.CheckViolation
                : DbFailure.ForeignKeyViolation,          // 547 covers both FK and CHECK
            _ => DbFailure.Unknown,
        },
        PostgresException pg => pg.SqlState switch
        {
            "23505" => DbFailure.UniqueViolation,
            "23503" => DbFailure.ForeignKeyViolation,
            "23514" => DbFailure.CheckViolation,
            _ => DbFailure.Unknown,
        },
        _ => DbFailure.Unknown,
    };

    /// <summary>
    /// SQL Server reports FK and CHECK failures under the same error number, so the
    /// only way to tell them apart is the constraint name in the message. The
    /// schema names every check constraint CK_*, which makes this reliable here even
    /// though it would not be in general.
    /// </summary>
    private static bool ConstraintNameSuggestsCheck(string message) =>
        message.Contains("CK_", StringComparison.OrdinalIgnoreCase);

    /// <summary>The driver's own message, which is the useful part for a proof of concept.</summary>
    public static string Detail(DbUpdateException exception) =>
        exception.InnerException?.Message ?? exception.Message;
}
