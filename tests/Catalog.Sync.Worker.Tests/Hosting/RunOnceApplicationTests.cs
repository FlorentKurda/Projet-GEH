using Catalog.Contracts;
using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Hosting;
using Microsoft.Extensions.Logging.Abstractions;

namespace Catalog.Sync.Worker.Tests.Hosting;

public sealed class RunOnceApplicationTests
{
    [Fact]
    public async Task ExecuteAsync_StartsExactlyOneSynchronizationAndCompletes()
    {
        var synchronizationService = new StubSynchronizationService();
        var application = CreateApplication(synchronizationService);

        var exitCode = await application
            .ExecuteAsync(CancellationToken.None)
            .WaitAsync(TimeSpan.FromSeconds(1));

        Assert.Equal(0, exitCode);
        Assert.Equal(1, synchronizationService.CallCount);
    }

    [Fact]
    public async Task ExecuteAsync_PropagatesFailureAsNonZeroExitCode()
    {
        var synchronizationService = new StubSynchronizationService
        {
            Exception = new InvalidOperationException("Échec de test déterministe."),
        };
        var application = CreateApplication(synchronizationService);

        var exitCode = await application
            .ExecuteAsync(CancellationToken.None)
            .WaitAsync(TimeSpan.FromSeconds(1));

        Assert.Equal(1, exitCode);
        Assert.Equal(1, synchronizationService.CallCount);
    }

    private static RunOnceApplication CreateApplication(
        ICatalogSynchronizationService synchronizationService)
    {
        return new RunOnceApplication(
            synchronizationService,
            NullLogger<RunOnceApplication>.Instance);
    }

    private sealed class StubSynchronizationService : ICatalogSynchronizationService
    {
        public int CallCount { get; private set; }

        public Exception? Exception { get; init; }

        public Task<SyncResult> SynchronizeAsync(CancellationToken cancellationToken)
        {
            CallCount++;
            cancellationToken.ThrowIfCancellationRequested();

            if (Exception is not null)
            {
                return Task.FromException<SyncResult>(Exception);
            }

            return Task.FromResult(new SyncResult
            {
                RunId = Guid.Parse("71c7ea7a-55c4-4fc0-a721-6ac4cd8e3280"),
                Status = "success",
                ReceivedCount = 60,
                InsertedCount = 60,
                UpdatedCount = 0,
            });
        }
    }
}
