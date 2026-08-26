using Catalog.Contracts;
using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Errors;
using Catalog.Sync.Worker.Products;
using Catalog.Sync.Worker.Synchronization;
using Microsoft.Extensions.Logging.Abstractions;

namespace Catalog.Sync.Worker.Tests.Synchronization;

public sealed class CatalogSynchronizationServiceTests
{
    [Fact]
    public async Task SynchronizeAsync_NormalizesProductsAndBuildsVersionOneRequest()
    {
        var source = new StubProductSource(
        [
            CreateProduct() with
            {
                SourceId = "  MOCK-0001  ",
                Reference = "  REF-0001  ",
                Name = "  Produit exemple  ",
            },
        ]);
        var client = new CapturingWordPressClient();
        using var service = CreateService(source, client);

        var result = await service.SynchronizeAsync(CancellationToken.None);

        Assert.Equal("success", result.Status);
        Assert.NotNull(client.Request);
        Assert.Equal(1, client.Request.SchemaVersion);
        Assert.NotEqual(Guid.Empty, client.Request.RunId);
        var product = Assert.Single(client.Request.Products);
        Assert.Equal("MOCK-0001", product.SourceId);
        Assert.Equal("REF-0001", product.Reference);
        Assert.Equal("Produit exemple", product.Name);
    }

    [Fact]
    public async Task SynchronizeAsync_RejectsDuplicateSourceIdsBeforeHttpCall()
    {
        var source = new StubProductSource(
        [
            CreateProduct(),
            CreateProduct() with { Reference = "REF-0002" },
        ]);
        var client = new CapturingWordPressClient();
        using var service = CreateService(source, client);

        await Assert.ThrowsAsync<ProductValidationException>(
            () => service.SynchronizeAsync(CancellationToken.None));

        Assert.Null(client.Request);
    }

    private static CatalogSynchronizationService CreateService(
        IProductSource source,
        IWordPressCatalogClient client)
    {
        return new CatalogSynchronizationService(
            source,
            new ProductSyncItemValidator(),
            client,
            TimeProvider.System,
            NullLogger<CatalogSynchronizationService>.Instance);
    }

    private static ProductSyncItem CreateProduct()
    {
        return new ProductSyncItem
        {
            SourceId = "MOCK-0001",
            Reference = "REF-0001",
            Name = "Produit exemple",
        };
    }

    private sealed class StubProductSource : IProductSource
    {
        private readonly IReadOnlyCollection<ProductSyncItem> _products;

        public StubProductSource(IReadOnlyCollection<ProductSyncItem> products)
        {
            _products = products;
        }

        public Task<IReadOnlyCollection<ProductSyncItem>> GetProductsAsync(
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(_products);
        }
    }

    private sealed class CapturingWordPressClient : IWordPressCatalogClient
    {
        public ProductSyncRequest? Request { get; private set; }

        public Task<SyncResult> SynchronizeAsync(
            ProductSyncRequest request,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Request = request;
            return Task.FromResult(new SyncResult
            {
                RunId = request.RunId,
                Status = "success",
                ReceivedCount = request.Products.Count,
                InsertedCount = request.Products.Count,
                UpdatedCount = 0,
            });
        }
    }
}
