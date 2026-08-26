using Catalog.Contracts;

namespace Catalog.Sync.Worker.Abstractions;

public interface IWordPressCatalogClient
{
    Task<SyncResult> SynchronizeAsync(
        ProductSyncRequest request,
        CancellationToken cancellationToken);
}
