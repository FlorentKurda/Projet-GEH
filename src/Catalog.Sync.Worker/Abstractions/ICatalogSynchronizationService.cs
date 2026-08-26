using Catalog.Contracts;

namespace Catalog.Sync.Worker.Abstractions;

public interface ICatalogSynchronizationService
{
    Task<SyncResult> SynchronizeAsync(CancellationToken cancellationToken);
}
