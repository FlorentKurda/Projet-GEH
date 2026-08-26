using Catalog.Contracts;

namespace Catalog.Sync.Worker.Abstractions;

public interface IProductSyncItemValidator
{
    ProductSyncItem ValidateAndNormalize(ProductSyncItem product);
}
