using Catalog.Contracts;

namespace Catalog.Sync.Worker.Abstractions;

public interface IProductSource
{
    Task<IReadOnlyCollection<ProductSyncItem>> GetProductsAsync(
        CancellationToken cancellationToken);
}
