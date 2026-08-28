using Catalog.Contracts;
using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Configuration;
using Catalog.Sync.Worker.Errors;
using Catalog.Sync.Worker.Products;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker.Synchronization;

public sealed class CatalogSynchronizationService : ICatalogSynchronizationService, IDisposable
{
    public const int MaximumBatchSize = 500;

    private readonly IProductSource _productSource;
    private readonly IProductSyncItemValidator _validator;
    private readonly IWordPressCatalogClient _wordPressClient;
    private readonly int _batchSize;
    private readonly ILogger<CatalogSynchronizationService> _logger;
    private readonly SemaphoreSlim _synchronizationGate = new(1, 1);

    public CatalogSynchronizationService(
        IProductSource productSource,
        IProductSyncItemValidator validator,
        IWordPressCatalogClient wordPressClient,
        IOptions<SyncOptions> options,
        ILogger<CatalogSynchronizationService> logger)
    {
        _productSource = productSource ?? throw new ArgumentNullException(nameof(productSource));
        _validator = validator ?? throw new ArgumentNullException(nameof(validator));
        _wordPressClient = wordPressClient ?? throw new ArgumentNullException(nameof(wordPressClient));
        ArgumentNullException.ThrowIfNull(options);
        _batchSize = options.Value.BatchSize;
        if (_batchSize is < 1 or > MaximumBatchSize)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                $"La taille de batch doit être comprise entre 1 et {MaximumBatchSize}.");
        }

        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    public async Task<SyncResult> SynchronizeAsync(
        bool dryRun,
        CancellationToken cancellationToken)
    {
        if (!await _synchronizationGate.WaitAsync(TimeSpan.Zero, cancellationToken))
        {
            throw new SynchronizationAlreadyRunningException();
        }

        try
        {
            var sourceProducts = await _productSource.GetProductsAsync(cancellationToken);
            var products = ValidateNormalizeAndHash(sourceProducts, cancellationToken);
            var expectedBatchCount = products.Count == 0
                ? 0
                : (int)Math.Ceiling(products.Count / (double)_batchSize);

            var startResult = await _wordPressClient.StartRunAsync(
                new StartSyncRunRequest
                {
                    RunId = Guid.NewGuid(),
                    ExpectedProductCount = products.Count,
                    ExpectedBatchCount = expectedBatchCount,
                    Source = "json-fixture",
                    DryRun = dryRun,
                },
                cancellationToken);

            _logger.LogInformation(
                "Run {RunId} démarré avec {ProductCount} produits en {BatchCount} batch(es). Dry-run : {DryRun}.",
                startResult.RunId,
                products.Count,
                expectedBatchCount,
                dryRun);

            for (var offset = 0; offset < products.Count; offset += _batchSize)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var batchNumber = (offset / _batchSize) + 1;
                var batch = products.Skip(offset).Take(_batchSize).ToArray();
                var batchResult = await _wordPressClient.SendBatchAsync(
                    startResult.RunId,
                    new ProductSyncBatchRequest
                    {
                        BatchNumber = batchNumber,
                        Products = batch,
                    },
                    cancellationToken);

                _logger.LogInformation(
                    "Batch {BatchNumber}/{BatchCount} du run {RunId} accepté ({ProductCount} produits, replay : {Replayed}).",
                    batchNumber,
                    expectedBatchCount,
                    startResult.RunId,
                    batchResult.ReceivedCount,
                    batchResult.Replayed);
            }

            var result = await _wordPressClient.CompleteRunAsync(
                startResult.RunId,
                cancellationToken);

            LogResult(result, products.Count);
            return result;
        }
        finally
        {
            _synchronizationGate.Release();
        }
    }

    public void Dispose() => _synchronizationGate.Dispose();

    private IReadOnlyList<ProductSyncPayloadItem> ValidateNormalizeAndHash(
        IReadOnlyCollection<ProductSyncItem> sourceProducts,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(sourceProducts);

        var products = new List<ProductSyncPayloadItem>(sourceProducts.Count);
        var sourceIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var sourceProduct in sourceProducts)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var normalized = _validator.ValidateAndNormalize(sourceProduct);
            if (!sourceIds.Add(normalized.SourceId))
            {
                throw new ProductValidationException(
                    $"Le SourceId '{normalized.SourceId}' est présent plusieurs fois.");
            }

            products.Add(ProductContentHasher.CreatePayload(normalized));
        }

        return products;
    }

    private void LogResult(SyncResult result, int sourceProductCount)
    {
        if (result.DryRun)
        {
            _logger.LogInformation(
                "Dry-run {RunId} : Produits source : {SourceCount}; Nouveaux : {InsertedCount}; " +
                "Modifiés : {UpdatedCount}; Inchangés : {UnchangedCount}; À réactiver : {ReactivatedCount}; " +
                "À désactiver : {CandidateDeactivationCount}; Désactivation : {DeactivationPercentage} %; " +
                "Garde-fou : {GuardrailStatus}. Aucune modification effectuée.",
                result.RunId,
                sourceProductCount,
                result.InsertedCount,
                result.UpdatedCount,
                result.UnchangedCount,
                result.ReactivatedCount,
                result.CandidateDeactivationCount,
                result.DeactivationPercentage,
                result.GuardrailStatus);
            return;
        }

        _logger.LogInformation(
            "Run {RunId} terminé : {ReceivedCount} reçus, {InsertedCount} insérés, " +
            "{UpdatedCount} modifiés, {UnchangedCount} inchangés, {ReactivatedCount} réactivés, " +
            "{DeactivatedCount} désactivés.",
            result.RunId,
            result.ReceivedCount,
            result.InsertedCount,
            result.UpdatedCount,
            result.UnchangedCount,
            result.ReactivatedCount,
            result.DeactivatedCount);
    }
}
