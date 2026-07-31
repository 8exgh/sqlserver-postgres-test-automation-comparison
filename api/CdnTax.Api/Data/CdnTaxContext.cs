using CdnTax.Api.Entities;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata;
using Microsoft.EntityFrameworkCore.Storage.ValueConversion;

namespace CdnTax.Api.Data;

/// <summary>
/// One context for both engines.
///
/// Every table and column below is named in lower case, and that is load-bearing
/// rather than stylistic. EF Core quotes every identifier it emits. SQL Server's
/// database collation here is SQL_Latin1_General_CP1_CI_AS, so <c>[clientid]</c>
/// resolves case-insensitively to <c>ClientId</c>; every PostgreSQL object was
/// created unquoted and is therefore already lower case. One set of names binds on
/// both - the same property db/README.md and app/src/query.cpp rely on.
///
/// What does *not* come for free is type. The PostgreSQL port renders BIT as
/// NUMERIC(1,0), ROWVERSION as a trigger-fed BIGINT, and TINYINT as SMALLINT.
/// Those are the only differences, and they are collected in
/// <see cref="ApplyPostgresTypes"/> / <see cref="ApplySqlServerTypes"/> so the
/// divergence reads as a checklist rather than being scattered through the model.
/// </summary>
public sealed class CdnTaxContext(DbContextOptions<CdnTaxContext> options) : DbContext(options)
{
    public DbSet<Client> Clients => Set<Client>();
    public DbSet<Engagement> Engagements => Set<Engagement>();
    public DbSet<Practitioner> Practitioners => Set<Practitioner>();
    public DbSet<Province> Provinces => Set<Province>();
    public DbSet<TaxYear> TaxYears => Set<TaxYear>();

    /// <summary>
    /// UTC now, truncated to milliseconds, with <see cref="DateTimeKind.Unspecified"/>.
    ///
    /// Two separate reasons, both load-bearing. The kind is stripped because both
    /// engines store these columns without a time zone (DATETIME2(3) / timestamp(3)
    /// without time zone) and Npgsql refuses outright to write a <c>Kind.Utc</c>
    /// value into the latter. The truncation is because scale 3 is what the columns
    /// keep: without it the value echoed back in the response carries ticks the
    /// database silently dropped, so the response would not match a subsequent read -
    /// and the two engines round differently.
    /// </summary>
    public static DateTime UtcNowNaive()
    {
        var now = DateTime.UtcNow;
        return new DateTime(
            now.Ticks - (now.Ticks % TimeSpan.TicksPerMillisecond),
            DateTimeKind.Unspecified);
    }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        var postgres = Database.IsNpgsql();

        ConfigureClient(modelBuilder, postgres);
        ConfigureEngagement(modelBuilder);
        ConfigurePractitioner(modelBuilder, postgres);
        ConfigureProvince(modelBuilder, postgres);
        ConfigureTaxYear(modelBuilder, postgres);
    }

    private static void ConfigureClient(ModelBuilder modelBuilder, bool postgres)
    {
        modelBuilder.Entity<Client>(b =>
        {
            if (postgres)
            {
                b.ToTable("client", "client");
            }
            else
            {
                // Mandatory, not an optimisation. client.tr_Client_Audit is an AFTER
                // trigger on this table, and SQL Server rejects the OUTPUT clause EF
                // generates for writes when the target table has enabled triggers
                // ("...cannot have any enabled triggers if the statement contains an
                // OUTPUT clause without INTO"). Declaring the trigger makes EF fall
                // back to a separate SELECT for generated values.
                b.ToTable("client", "client", t => t.HasTrigger("tr_Client_Audit"));
            }

            b.HasKey(x => x.ClientId);
            b.Property(x => x.ClientId).HasColumnName("clientid").ValueGeneratedOnAdd();

            b.Property(x => x.ClientCode).HasColumnName("clientcode").HasMaxLength(20).IsRequired();
            b.Property(x => x.ClientType).HasColumnName("clienttype").HasMaxLength(1).IsFixedLength().IsRequired();

            b.Property(x => x.FirstName).HasColumnName("firstname").HasMaxLength(50);
            b.Property(x => x.LastName).HasColumnName("lastname").HasMaxLength(50);
            b.Property(x => x.DateOfBirth).HasColumnName("dateofbirth");
            b.Property(x => x.Sin).HasColumnName("sin").HasMaxLength(9).IsFixedLength();
            b.Property(x => x.MaritalStatus).HasColumnName("maritalstatus").HasMaxLength(20);

            b.Property(x => x.LegalName).HasColumnName("legalname").HasMaxLength(150);
            b.Property(x => x.IncorporationDate).HasColumnName("incorporationdate");
            b.Property(x => x.BusinessNumber).HasColumnName("businessnumber").HasMaxLength(9).IsFixedLength();
            b.Property(x => x.FiscalYearEndMonth).HasColumnName("fiscalyearendmonth");

            b.Property(x => x.ProvinceCode).HasColumnName("provincecode").HasMaxLength(2).IsFixedLength().IsRequired();
            b.Property(x => x.OnboardedDate).HasColumnName("onboardeddate");
            b.Property(x => x.IsActive).HasColumnName("isactive");

            // PERSISTED / GENERATED ALWAYS STORED. Read it back after every write,
            // never send it - SQL Server errors on writes to a computed column and
            // PostgreSQL errors on writes to a generated one.
            b.Property(x => x.DisplayName)
                .HasColumnName("displayname")
                .HasMaxLength(150)
                .ValueGeneratedOnAddOrUpdate()
                .Metadata.SetBeforeSaveBehavior(PropertySaveBehavior.Ignore);
            b.Property(x => x.DisplayName).Metadata.SetAfterSaveBehavior(PropertySaveBehavior.Ignore);

            // Defaulted by the database on both (SYSUTCDATETIME() / timezone('UTC', ...)).
            b.Property(x => x.CreatedAt).HasColumnName("createdat").ValueGeneratedOnAdd();
            b.Property(x => x.UpdatedAt).HasColumnName("updatedat");

            b.HasOne(x => x.Province)
                .WithMany()
                .HasForeignKey(x => x.ProvinceCode)
                .HasPrincipalKey(p => p.ProvinceCode);

            b.HasMany(x => x.Engagements)
                .WithOne(e => e.Client!)
                .HasForeignKey(e => e.ClientId);

            if (postgres) ApplyPostgresTypes(b);
            else ApplySqlServerTypes(b);
        });
    }

    /// <summary>
    /// The three places client.Client differs in type on the port.
    /// </summary>
    private static void ApplyPostgresTypes(Microsoft.EntityFrameworkCore.Metadata.Builders.EntityTypeBuilder<Client> b)
    {
        // BIT -> NUMERIC(1,0). SCT chose numeric rather than boolean, so a CLR bool
        // needs a converter; without it Npgsql would emit a boolean literal and the
        // insert would fail on type mismatch.
        b.Property(x => x.IsActive)
            .HasColumnType("numeric(1,0)")
            .HasConversion(new BoolToZeroOneConverter<decimal>());

        // TINYINT -> SMALLINT. PostgreSQL has no one-byte integer, and Npgsql has no
        // default mapping for a CLR byte, so the cast is explicit. Keeping the CLR
        // type as byte is what lets SQL Server map it natively to tinyint.
        b.Property(x => x.FiscalYearEndMonth).HasConversion<short?>().HasColumnType("smallint");

        b.Property(x => x.CreatedAt).HasColumnType("timestamp(3) without time zone");
        b.Property(x => x.UpdatedAt).HasColumnType("timestamp(3) without time zone");

        // ROWVERSION has no PostgreSQL equivalent, so the port emulates it: a plain
        // BIGINT that trigger client.tr_client_biu overwrites from a sequence. That
        // trigger *raises* if the column is non-null on INSERT or changed on UPDATE,
        // so EF must never place it in a column list or a SET clause.
        // ValueGeneratedOnAddOrUpdate is exactly that contract - excluded from writes,
        // read back afterwards - while IsConcurrencyToken still puts the original
        // value in the WHERE predicate.
        b.Property(x => x.RowVersion)
            .HasColumnName("rowversion")
            .HasColumnType("bigint")
            .IsConcurrencyToken()
            .ValueGeneratedOnAddOrUpdate();
    }

    private static void ApplySqlServerTypes(Microsoft.EntityFrameworkCore.Metadata.Builders.EntityTypeBuilder<Client> b)
    {
        b.Property(x => x.IsActive).HasColumnType("bit");
        b.Property(x => x.FiscalYearEndMonth).HasColumnType("tinyint");
        b.Property(x => x.CreatedAt).HasColumnType("datetime2(3)");
        b.Property(x => x.UpdatedAt).HasColumnType("datetime2(3)");

        // Native ROWVERSION: 8 opaque bytes the engine maintains. Surfacing it as a
        // long keeps one CLR shape across both providers and keeps it JSON-friendly.
        // NumberToBytesConverter round-trips it; the byte order is not SQL Server's
        // big-endian reading, which is irrelevant because the value is only ever
        // compared for equality against one this same converter produced.
        b.Property(x => x.RowVersion)
            .HasColumnName("rowversion")
            .IsRowVersion()
            .HasConversion(new NumberToBytesConverter<long>());
    }

    private static void ConfigureEngagement(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Engagement>(b =>
        {
            b.ToTable("engagement", "client");
            b.HasKey(x => x.EngagementId);
            b.Property(x => x.EngagementId).HasColumnName("engagementid").ValueGeneratedOnAdd();
            b.Property(x => x.ClientId).HasColumnName("clientid");
            b.Property(x => x.TaxYear).HasColumnName("taxyear");
            b.Property(x => x.ServiceType).HasColumnName("servicetype").HasMaxLength(30).IsRequired();
            b.Property(x => x.PractitionerId).HasColumnName("practitionerid");
            b.Property(x => x.Status).HasColumnName("status").HasMaxLength(20).IsRequired();
            b.Property(x => x.FeeQuoted).HasColumnName("feequoted").HasPrecision(19, 2);
            b.Property(x => x.FeeBilled).HasColumnName("feebilled").HasPrecision(19, 2);
            b.Property(x => x.StartedOn).HasColumnName("startedon");
            b.Property(x => x.CompletedOn).HasColumnName("completedon");

            b.HasOne(x => x.Practitioner).WithMany().HasForeignKey(x => x.PractitionerId);
        });
    }

    private static void ConfigurePractitioner(ModelBuilder modelBuilder, bool postgres)
    {
        modelBuilder.Entity<Practitioner>(b =>
        {
            b.ToTable("practitioner", "client");
            b.HasKey(x => x.PractitionerId);
            b.Property(x => x.PractitionerId).HasColumnName("practitionerid").ValueGeneratedOnAdd();
            b.Property(x => x.FullName).HasColumnName("fullname").HasMaxLength(100).IsRequired();
            b.Property(x => x.Designation).HasColumnName("designation").HasMaxLength(20);
            b.Property(x => x.Email).HasColumnName("email").HasMaxLength(150).IsRequired();
            b.Property(x => x.IsPartner).HasColumnName("ispartner");
            b.Property(x => x.IsActive).HasColumnName("isactive");

            if (!postgres) return;
            b.Property(x => x.IsPartner).HasColumnType("numeric(1,0)").HasConversion(new BoolToZeroOneConverter<decimal>());
            b.Property(x => x.IsActive).HasColumnType("numeric(1,0)").HasConversion(new BoolToZeroOneConverter<decimal>());
        });
    }

    private static void ConfigureProvince(ModelBuilder modelBuilder, bool postgres)
    {
        modelBuilder.Entity<Province>(b =>
        {
            b.ToTable("province", "ref");
            b.HasKey(x => x.ProvinceCode);
            b.Property(x => x.ProvinceCode).HasColumnName("provincecode").HasMaxLength(2).IsFixedLength();
            b.Property(x => x.ProvinceName).HasColumnName("provincename").HasMaxLength(50).IsRequired();
            b.Property(x => x.IsTerritory).HasColumnName("isterritory");
            b.Property(x => x.SortOrder).HasColumnName("sortorder");

            if (!postgres) return;
            b.Property(x => x.IsTerritory).HasColumnType("numeric(1,0)").HasConversion(new BoolToZeroOneConverter<decimal>());
            b.Property(x => x.SortOrder).HasConversion<short>().HasColumnType("smallint");
        });
    }

    private static void ConfigureTaxYear(ModelBuilder modelBuilder, bool postgres)
    {
        modelBuilder.Entity<TaxYear>(b =>
        {
            b.ToTable("taxyear", "ref");
            b.HasKey(x => x.Year);
            b.Property(x => x.Year).HasColumnName("taxyear").ValueGeneratedNever();
            b.Property(x => x.T1FilingDeadline).HasColumnName("t1filingdeadline");
            b.Property(x => x.SelfEmployedDeadline).HasColumnName("selfemployeddeadline");
            b.Property(x => x.RrspDeadline).HasColumnName("rrspdeadline");
            b.Property(x => x.InstallmentThreshold).HasColumnName("installmentthreshold").HasPrecision(19, 2);
            b.Property(x => x.IsLocked).HasColumnName("islocked");

            if (!postgres) return;
            b.Property(x => x.IsLocked).HasColumnType("numeric(1,0)").HasConversion(new BoolToZeroOneConverter<decimal>());
        });
    }
}
