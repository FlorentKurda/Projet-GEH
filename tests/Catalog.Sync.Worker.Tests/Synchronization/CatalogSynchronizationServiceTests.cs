using Catalog.Contracts;
using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Configuration;
using Catalog.Sync.Worker.Errors;
using Catalog.Sync.Worker.Products;
using Catalog.Sync.Worker.Synchronization;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker.Tests.Synchronization;

public sealed class CatalogSynchronizationServiceTests
{
    [Fact]
    public async Task SynchronizeAsync_UsesVersionTwoRunAndNormalizedHashedProducts()
    {
        var source = new StubProductSource(
        [
            CreateProduct(1) with
            {
                SourceId = "  MOCK-0001  ",
                Reference = "  REF-0001  ",
                Name = "  Produit exemple  ",
            },
        ]);
        var client = new CapturingWordPressClient();
        using var service = CreateService(source, client);

        var result = await service.SynchronizeAsync(false, CancellationToken.None);

        Assert.Equal("completed", result.Status);
        Assert.NotNull(client.StartRequest);
        Assert.Equal(2, client.StartRequest.SchemaVersion);
        Assert.NotEqual(Guid.Empty, client.StartRequest.RunId);
        Assert.Equal(client.StartRequest.RunId, client.StartRunId);
        Assert.Equal(1, client.StartRequest.ExpectedProductCount);
        Assert.Equal(1, client.StartRequest.ExpectedBatchCount);
        var product = Assert.Single(Assert.Single(client.Batches).Products);
        Assert.Equal("MOCK-0001", product.SourceId);
        Assert.Equal("REF-0001", product.Reference);
        Assert.Equal("Produit exemple", product.Name);
        Assert.Equal(64, product.ContentHash.Length);
        Assert.Equal(client.StartRequest.RunId, client.CompletedRunId);
    }

    [Fact]
    public async Task SynchronizeAsync_SplitsProductsIntoConfiguredBatches()
    {
        var source = new StubProductSource(
            Enumerable.Range(1, 5).Select(CreateProduct).ToArray());
        var client = new CapturingWordPressClient();
        using var service = CreateService(source, client, batchSize: 2);

        await service.SynchronizeAsync(false, CancellationToken.None);

        Assert.Equal(3, client.StartRequest!.ExpectedBatchCount);
        Assert.Equal([1, 2, 3], client.Batches.Select(batch => batch.BatchNumber));
        Assert.Equal([2, 2, 1], client.Batches.Select(batch => batch.Products.Count));
        Assert.Equal(1, client.CompleteCallCount);
    }

    [Fact]
    public async Task SynchronizeAsync_PropagatesDryRunThroughWholeRun()
    {
        var client = new CapturingWordPressClient();
        using var service = CreateService(
            new StubProductSource([CreateProduct(1)]),
            client);

        var result = await service.SynchronizeAsync(true, CancellationToken.None);

        Assert.True(client.StartRequest!.DryRun);
        Assert.True(result.DryRun);
        Assert.Equal(1, client.CompleteCallCount);
    }

    [Fact]
    public async Task SynchronizeAsync_RejectsDuplicateSourceIdsIgnoringCaseBeforeHttpCall()
    {
        var source = new StubProductSource(
        [
            CreateProduct(1),
            CreateProduct(2) with { SourceId = "mock-0001" },
        ]);
        var client = new CapturingWordPressClient();
        using var service = CreateService(source, client);

        await Assert.ThrowsAsync<ProductValidationException>(
            () => service.SynchronizeAsync(false, CancellationToken.None));

        Assert.Null(client.StartRequest);
    }

    [Fact]
    public async Task SynchronizeAsync_SendsEmptySourceToServerForSafeRejection()
    {
        var client = new CapturingWordPressClient
        {
            StartException = new WordPressCatalogException("Empty source rejected."),
        };
        using var service = CreateService(
            new StubProductSource([]),
            client);

        await Assert.ThrowsAsync<WordPressCatalogException>(
            () => service.SynchronizeAsync(false, CancellationToken.None));

        Assert.Equal(0, client.StartRequest!.ExpectedProductCount);
        Assert.Equal(0, client.StartRequest.ExpectedBatchCount);
        Assert.Empty(client.Batches);
        Assert.Equal(0, client.CompleteCallCount);
    }

    [Fact]
    public async Task SynchronizeAsync_DoesNotCompleteInterruptedRun()
    {
        var client = new CapturingWordPressClient { CancelOnBatchNumber = 2 };
        using var service = CreateService(
            new StubProductSource(Enumerable.Range(1, 3).Select(CreateProduct).ToArray()),
            client,
            batchSize: 1);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => service.SynchronizeAsync(false, CancellationToken.None));

        Assert.Equal(2, client.Batches.Count);
        Assert.Equal(0, client.CompleteCallCount);
    }

    [Fact]
    public async Task SynchronizeAsync_RejectsConcurrentLocalRun()
    {
        var source = new BlockingProductSource();
        var client = new CapturingWordPressClient();
        using var service = CreateService(source, client);
        var firstRun = service.SynchronizeAsync(false, CancellationToken.None);
        await source.Entered.Task.WaitAsync(TimeSpan.FromSeconds(1));

        await Assert.ThrowsAsync<SynchronizationAlreadyRunningException>(
            () => service.SynchronizeAsync(false, CancellationToken.None));

        source.Release.SetResult([CreateProduct(1)]);
        await firstRun;
    }

    private static CatalogSynchronizationService CreateService(
        IProductSource source,
        IWordPressCatalogClient client,
        int batchSize = 200) => new(
            source,
            new ProductSyncItemValidator(),
            client,
            Options.Create(new SyncOptions { BatchSize = batchSize }),
            NullLogger<CatalogSynchronizationService>.Instance);

    private static ProductSyncItem CreateProduct(int number) => new()
    {
        SourceId = $"MOCK-{number:0000}",
        Reference = $"REF-{number:0000}",
        Name = $"Produit {number:0000}",
        Brand = "Marque déterministe",
    };

    private sealed class StubProductSource(IReadOnlyCollection<ProductSyncItem> products)
        : IProductSource
    {
        public Task<IReadOnlyCollection<ProductSyncItem>> GetProductsAsync(
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(products);
        }
    }

    private sealed class BlockingProductSource : IProductSource
    {
        public TaskCompletionSource<bool> Entered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public TaskCompletionSource<IReadOnlyCollection<ProductSyncItem>> Release { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<IReadOnlyCollection<ProductSyncItem>> GetProductsAsync(
            CancellationToken cancellationToken)
        {
            Entered.SetResult(true);
            return await Release.Task.WaitAsync(cancellationToken);
        }
    }

    private sealed class CapturingWordPressClient : IWordPressCatalogClient
    {
        private int _receivedCount;

        public StartSyncRunRequest? StartRequest { get; private set; }

        public Guid? StartRunId { get; private set; }

        public List<ProductSyncBatchRequest> Batches { get; } = [];

        public Guid? CompletedRunId { get; private set; }

        public int CompleteCallCount { get; private set; }

        public int? CancelOnBatchNumber { get; init; }

        public Exception? StartException { get; init; }

        public Task<StartSyncRunResult> StartRunAsync(
            StartSyncRunRequest request,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            StartRequest = request;
            StartRunId = request.RunId;
            if (StartException is not null)
            {
                return Task.FromException<StartSyncRunResult>(StartException);
            }

            return Task.FromResult(new StartSyncRunResult
            {
                RunId = request.RunId,
                Status = "started",
            });
        }

        public Task<ProductSyncBatchResult> SendBatchAsync(
            Guid runId,
            ProductSyncBatchRequest request,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Batches.Add(request);
            if (CancelOnBatchNumber == request.BatchNumber)
            {
                return Task.FromCanceled<ProductSyncBatchResult>(new CancellationToken(true));
            }

            _receivedCount += request.Products.Count;
            return Task.FromResult(new ProductSyncBatchResult
            {
                RunId = runId,
                BatchNumber = request.BatchNumber,
                Status = "running",
                Replayed = false,
                ReceivedCount = request.Products.Count,
                InsertedCount = 0,
                UpdatedCount = 0,
                UnchangedCount = request.Products.Count,
                ReactivatedCount = 0,
            });
        }

        public Task<SyncResult> CompleteRunAsync(
            Guid runId,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            CompleteCallCount++;
            CompletedRunId = runId;
            return Task.FromResult(new SyncResult
            {
                RunId = runId,
                Status = "completed",
                ReceivedCount = _receivedCount,
                InsertedCount = 0,
                UpdatedCount = 0,
                UnchangedCount = _receivedCount,
                ReactivatedCount = 0,
                DeactivatedCount = 0,
                CandidateDeactivationCount = 0,
                ActiveBeforeCount = _receivedCount,
                DeactivationPercentage = 0,
                GuardrailStatus = "ok",
                DryRun = StartRequest!.DryRun,
            });
        }
    }
}
