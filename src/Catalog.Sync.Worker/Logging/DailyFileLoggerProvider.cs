using System.Text;
using Catalog.Sync.Worker.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Hosting.WindowsServices;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker.Logging;

public sealed class DailyFileLoggerProvider : ILoggerProvider
{
    private readonly object _gate = new();
    private readonly FileLoggingOptions _options;
    private readonly TimeProvider _timeProvider;
    private readonly string _directoryPath;
    private StreamWriter? _writer;
    private DateOnly? _openDate;
    private bool _disposed;

    public DailyFileLoggerProvider(
        IOptions<FileLoggingOptions> options,
        IHostEnvironment environment,
        TimeProvider timeProvider)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(environment);
        _timeProvider = timeProvider ?? throw new ArgumentNullException(nameof(timeProvider));
        _options = options.Value;
        _directoryPath = ResolveDirectoryPath(_options.DirectoryPath, environment.ContentRootPath);

        if (_options.Enabled)
        {
            Directory.CreateDirectory(_directoryPath);
            DeleteExpiredFiles(_timeProvider.GetLocalNow());
        }
    }

    public ILogger CreateLogger(string categoryName)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return new DailyFileLogger(this, categoryName);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _writer?.Dispose();
            _writer = null;
        }
    }

    internal bool IsEnabled(LogLevel logLevel) =>
        _options.Enabled && logLevel != LogLevel.None && !_disposed;

    internal void Write(
        string category,
        LogLevel logLevel,
        EventId eventId,
        string message,
        Exception? exception)
    {
        if (!IsEnabled(logLevel) || (message.Length == 0 && exception is null))
        {
            return;
        }

        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            var now = _timeProvider.GetLocalNow();
            EnsureWriter(now);
            _writer!.Write(now.ToString("yyyy-MM-dd HH:mm:ss.fff zzz"));
            _writer.Write(" [");
            _writer.Write(logLevel.ToString().ToUpperInvariant());
            _writer.Write("] ");
            _writer.Write(category);
            if (eventId.Id != 0)
            {
                _writer.Write(" [");
                _writer.Write(eventId.Id);
                _writer.Write(']');
            }

            _writer.Write(" - ");
            _writer.WriteLine(message);
            if (exception is not null)
            {
                _writer.WriteLine(exception);
            }

            _writer.Flush();
        }
    }

    private void EnsureWriter(DateTimeOffset now)
    {
        var currentDate = DateOnly.FromDateTime(now.DateTime);
        if (_writer is not null && _openDate == currentDate)
        {
            return;
        }

        _writer?.Dispose();
        Directory.CreateDirectory(_directoryPath);
        DeleteExpiredFiles(now);

        var path = Path.Combine(
            _directoryPath,
            $"catalog-sync-{currentDate:yyyy-MM-dd}.log");
        var stream = new FileStream(
            path,
            FileMode.Append,
            FileAccess.Write,
            FileShare.ReadWrite);
        _writer = new StreamWriter(stream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        _openDate = currentDate;
    }

    private void DeleteExpiredFiles(DateTimeOffset now)
    {
        var cutoff = now.Date.AddDays(-_options.RetentionDays);
        foreach (var path in Directory.EnumerateFiles(_directoryPath, "catalog-sync-*.log"))
        {
            try
            {
                if (File.GetLastWriteTime(path) < cutoff)
                {
                    File.Delete(path);
                }
            }
            catch (IOException)
            {
                // Une archive verrouillée sera réévaluée à la prochaine rotation.
            }
            catch (UnauthorizedAccessException)
            {
                // Le provider continue d'écrire le journal courant.
            }
        }
    }

    private static string ResolveDirectoryPath(string configuredPath, string contentRootPath)
    {
        var trimmedPath = configuredPath.Trim();
        if (Path.IsPathRooted(trimmedPath))
        {
            return Path.GetFullPath(trimmedPath);
        }

        var basePath = WindowsServiceHelpers.IsWindowsService()
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "GEH",
                "ProductCatalogSync")
            : contentRootPath;
        return Path.GetFullPath(trimmedPath, basePath);
    }

    private sealed class DailyFileLogger(
        DailyFileLoggerProvider provider,
        string categoryName) : ILogger
    {
        public IDisposable? BeginScope<TState>(TState state) where TState : notnull => null;

        public bool IsEnabled(LogLevel logLevel) => provider.IsEnabled(logLevel);

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            ArgumentNullException.ThrowIfNull(formatter);
            if (!IsEnabled(logLevel))
            {
                return;
            }

            provider.Write(
                categoryName,
                logLevel,
                eventId,
                formatter(state, exception),
                exception);
        }
    }
}
