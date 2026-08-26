namespace Catalog.Contracts;

public sealed record ProductSyncRequest
{
    public required int SchemaVersion { get; init; }

    public required Guid RunId { get; init; }

    public required DateTimeOffset SentAtUtc { get; init; }

    public required IReadOnlyCollection<ProductSyncItem> Products { get; init; }
}
