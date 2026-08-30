using System.Text;
using Catalog.Sync.Worker.Configuration;
using Catalog.Sync.Worker.Logging;
using Microsoft.Extensions.FileProviders;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Microsoft.Extensions.Time.Testing;

namespace Catalog.Sync.Worker.Tests.Logging;

public sealed class DailyFileLoggerProviderTests : IDisposable
{
    private readonly string _temporaryDirectory = Path.Combine(
        Path.GetTempPath(),
        $"catalog-file-logger-tests-{Guid.NewGuid():N}");

    public DailyFileLoggerProviderTests()
    {
        Directory.CreateDirectory(_temporaryDirectory);
    }

    [Fact]
    public void Logger_CreatesUtf8DailyFileAndWritesMessage()
    {
        var time = CreateTimeProvider();
        using var provider = CreateProvider(time);

        provider.CreateLogger("Test.Category").LogInformation("Produit été");

        var path = Assert.Single(Directory.GetFiles(_temporaryDirectory, "catalog-sync-*.log"));
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite);
        using var memory = new MemoryStream();
        stream.CopyTo(memory);
        var bytes = memory.ToArray();
        var content = new UTF8Encoding(false, true).GetString(bytes);
        Assert.False(bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble));
        Assert.Contains("Produit été", content, StringComparison.Ordinal);
        Assert.Contains("Test.Category", content, StringComparison.Ordinal);
    }

    [Fact]
    public void Logger_ChangesFileWhenDayChanges()
    {
        var time = CreateTimeProvider();
        using var provider = CreateProvider(time);
        var logger = provider.CreateLogger("Test");
        logger.LogInformation("Jour un");

        time.Advance(TimeSpan.FromDays(1));
        logger.LogInformation("Jour deux");

        Assert.Equal(2, Directory.GetFiles(_temporaryDirectory, "catalog-sync-*.log").Length);
    }

    [Fact]
    public void Provider_DeletesExpiredLogFiles()
    {
        var expiredPath = Path.Combine(_temporaryDirectory, "catalog-sync-2026-07-01.log");
        File.WriteAllText(expiredPath, "ancien");
        File.SetLastWriteTime(expiredPath, new DateTime(2026, 7, 1, 12, 0, 0));

        using var provider = CreateProvider(CreateTimeProvider(), retentionDays: 30);

        Assert.False(File.Exists(expiredPath));
    }

    [Fact]
    public void DisabledProviderDoesNotCreateOrWriteLog()
    {
        var disabledPath = Path.Combine(_temporaryDirectory, "disabled");
        using var provider = CreateProvider(
            CreateTimeProvider(),
            enabled: false,
            directoryPath: disabledPath);

        provider.CreateLogger("Test").LogInformation("Ignoré");

        Assert.False(Directory.Exists(disabledPath));
    }

    public void Dispose()
    {
        if (Directory.Exists(_temporaryDirectory))
        {
            Directory.Delete(_temporaryDirectory, recursive: true);
        }
    }

    private DailyFileLoggerProvider CreateProvider(
        TimeProvider timeProvider,
        bool enabled = true,
        int retentionDays = 30,
        string? directoryPath = null) =>
        new(
            Options.Create(new FileLoggingOptions
            {
                Enabled = enabled,
                DirectoryPath = directoryPath ?? _temporaryDirectory,
                RetentionDays = retentionDays,
            }),
            new TestHostEnvironment(_temporaryDirectory),
            timeProvider);

    private static FakeTimeProvider CreateTimeProvider() =>
        new(new DateTimeOffset(2026, 8, 30, 12, 0, 0, TimeSpan.Zero));

    private sealed class TestHostEnvironment(string contentRootPath) : IHostEnvironment
    {
        public string EnvironmentName { get; set; } = Environments.Development;

        public string ApplicationName { get; set; } = "Catalog.Sync.Worker.Tests";

        public string ContentRootPath { get; set; } = contentRootPath;

        public IFileProvider ContentRootFileProvider { get; set; } = new NullFileProvider();
    }
}
