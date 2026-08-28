namespace Catalog.Contracts;

public sealed record ProductSyncBatchRequest
{
    public required int BatchNumber { get; init; }

    public required IReadOnlyCollection<ProductSyncPayloadItem> Products { get; init; }
}
