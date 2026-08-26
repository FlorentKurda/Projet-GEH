namespace Catalog.Contracts;

public sealed record SyncResult
{
    public required Guid RunId { get; init; }

    public required string Status { get; init; }

    public required int ReceivedCount { get; init; }

    public required int InsertedCount { get; init; }

    public required int UpdatedCount { get; init; }
}
