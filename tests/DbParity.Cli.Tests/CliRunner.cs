using System.Diagnostics;
using System.Text;

namespace DbParity.Cli.Tests;

/// <summary>
/// What one invocation of <c>t1report</c> produced.
/// </summary>
/// <param name="ExitCode">
/// The tool documents four: 0 success, 2 usage, 3 connection, 4 query. Asserting
/// on these rather than on message text is what lets the tests stay meaningful
/// if the wording changes.
/// </param>
public sealed record CliResult(int ExitCode, string StdOut, string StdErr, string CommandLine)
{
    public bool Succeeded => ExitCode == 0;

    /// <summary>
    /// Everything the process said, for assertion messages. A failure that prints
    /// only "expected 0, got 3" wastes the reader's time; the driver's own
    /// diagnostics are usually the whole explanation.
    /// </summary>
    public string Detail =>
        $"$ {CommandLine}{Environment.NewLine}" +
        $"exit {ExitCode}{Environment.NewLine}" +
        (StdOut.Length > 0 ? $"--- stdout ---{Environment.NewLine}{StdOut}" : string.Empty) +
        (StdErr.Length > 0 ? $"--- stderr ---{Environment.NewLine}{StdErr}" : string.Empty);
}

/// <summary>
/// Runs the compiled C++ binary as a child process.
///
/// The tests deliberately drive the real executable rather than reimplementing
/// its query in C#: the point is to test the shipped application, including its
/// argument parsing, its two database drivers and its exit codes.
/// </summary>
public sealed class CliRunner
{
    // SQL Server's image is amd64-only and runs emulated on Apple Silicon, so a
    // cold first connection is slow. Generous enough not to be flaky, short
    // enough that a genuine hang still fails the run.
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(120);

    private readonly string _executable;

    public CliRunner(string executable) => _executable = executable;

    public CliResult Run(params string[] arguments) => Run(null, arguments);

    /// <summary>
    /// Runs the tool, optionally with extra environment variables. The tool reads
    /// its connection settings from the environment, so overriding them here is
    /// how the connection-failure paths get exercised without touching .env.
    /// </summary>
    public CliResult Run(IReadOnlyDictionary<string, string>? environment, params string[] arguments)
    {
        var info = new ProcessStartInfo(_executable)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };

        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        if (environment is not null)
        {
            foreach (var (key, value) in environment) info.Environment[key] = value;
        }

        using var process = new Process { StartInfo = info };

        // Read both streams asynchronously. Draining only one of them risks the
        // child blocking on a full pipe for the other, which would present as an
        // intermittent timeout.
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        process.OutputDataReceived += (_, e) => { if (e.Data is not null) stdout.AppendLine(e.Data); };
        process.ErrorDataReceived += (_, e) => { if (e.Data is not null) stderr.AppendLine(e.Data); };

        process.Start();
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        var commandLine = _executable + " " + string.Join(' ', arguments);

        if (!process.WaitForExit((int)Timeout.TotalMilliseconds))
        {
            try { process.Kill(entireProcessTree: true); } catch { /* already gone */ }
            throw new TimeoutException(
                $"t1report did not exit within {Timeout.TotalSeconds:0}s: {commandLine}");
        }

        // The overload taking a timeout returns once the process ends but does not
        // guarantee the async readers have flushed; the parameterless one does.
        process.WaitForExit();

        return new CliResult(process.ExitCode, stdout.ToString(), stderr.ToString(), commandLine);
    }
}
