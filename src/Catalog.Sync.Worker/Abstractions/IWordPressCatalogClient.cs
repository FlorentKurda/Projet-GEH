using Catalog.Contracts;

namespace Catalog.Sync.Worker.Abstractions;

public interface IWordPressCatalogClient
{
    Task<StartSyncRunResult> StartRunAsync(
        StartSyncRunRequest request,
        CancellationToken cancellationToken);

    Task<ProductSyncBatchResult> SendBatchAsync(
        Guid runId,
        ProductSyncBatchRequest request,
        CancellationToken cancellationToken);

    Task<SyncResult> CompleteRunAsync(
        Guid runId,
        CancellationToken cancellationToken);
}
