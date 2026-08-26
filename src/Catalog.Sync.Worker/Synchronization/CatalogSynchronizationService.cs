using Catalog.Contracts;
using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Errors;
using Microsoft.Extensions.Logging;

namespace Catalog.Sync.Worker.Synchronization;

public sealed class CatalogSynchronizationService : ICatalogSynchronizationService, IDisposable
{
    public const int MaximumProductsPerRequest = 500;

    private readonly IProductSource _productSource;
    private readonly IProductSyncItemValidator _validator;
    private readonly IWordPressCatalogClient _wordPressClient;
    private readonly TimeProvider _timeProvider;
    private readonly ILogger<CatalogSynchronizationService> _logger;
    private readonly SemaphoreSlim _synchronizationGate = new(1, 1);

    public CatalogSynchronizationService(
        IProductSource productSource,
        IProductSyncItemValidator validator,
        IWordPressCatalogClient wordPressClient,
        TimeProvider timeProvider,
        ILogger<CatalogSynchronizationService> logger)
    {
        _productSource = productSource ?? throw new ArgumentNullException(nameof(productSource));
        _validator = validator ?? throw new ArgumentNullException(nameof(validator));
        _wordPressClient = wordPressClient ?? throw new ArgumentNullException(nameof(wordPressClient));
        _timeProvider = timeProvider ?? throw new ArgumentNullException(nameof(timeProvider));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    public async Task<SyncResult> SynchronizeAsync(CancellationToken cancellationToken)
    {
        await _synchronizationGate.WaitAsync(cancellationToken);
        try
        {
            var sourceProducts = await _productSource.GetProductsAsync(cancellationToken);
            var products = ValidateAndNormalizeCollection(sourceProducts, cancellationToken);
            var request = new ProductSyncRequest
            {
                SchemaVersion = 1,
                RunId = Guid.NewGuid(),
                SentAtUtc = _timeProvider.GetUtcNow(),
                Products = products,
            };

            _logger.LogInformation(
                "Démarrage de la synchronisation {RunId} avec {ProductCount} produits.",
                request.RunId,
                products.Count);

            var result = await _wordPressClient.SynchronizeAsync(request, cancellationToken);

            _logger.LogInformation(
                "Synchronisation {RunId} terminée : {ReceivedCount} reçus, " +
                "{InsertedCount} insérés et {UpdatedCount} mis à jour.",
                result.RunId,
                result.ReceivedCount,
                result.InsertedCount,
                result.UpdatedCount);

            return result;
        }
        finally
        {
            _synchronizationGate.Release();
        }
    }

    public void Dispose()
    {
        _synchronizationGate.Dispose();
    }

    private IReadOnlyCollection<ProductSyncItem> ValidateAndNormalizeCollection(
        IReadOnlyCollection<ProductSyncItem> sourceProducts,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(sourceProducts);

        if (sourceProducts.Count == 0)
        {
            throw new ProductValidationException("La synchronisation doit contenir au moins un produit.");
        }

        if (sourceProducts.Count > MaximumProductsPerRequest)
        {
            throw new ProductValidationException(
                $"La synchronisation ne peut pas dépasser {MaximumProductsPerRequest} produits.");
        }

        var normalizedProducts = new List<ProductSyncItem>(sourceProducts.Count);
        var sourceIds = new HashSet<string>(StringComparer.Ordinal);

        foreach (var sourceProduct in sourceProducts)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var normalized = _validator.ValidateAndNormalize(sourceProduct);

            if (!sourceIds.Add(normalized.SourceId))
            {
                throw new ProductValidationException(
                    $"Le SourceId '{normalized.SourceId}' est présent plusieurs fois.");
            }

            normalizedProducts.Add(normalized);
        }

        return normalizedProducts;
    }
}
