namespace Catalog.Contracts;

public sealed record ProductSyncBatchResult
{
    public required Guid RunId { get; init; }

    public required int BatchNumber { get; init; }

    public required string Status { get; init; }

    public required bool Replayed { get; init; }

    public required int ReceivedCount { get; init; }

    public required int InsertedCount { get; init; }

    public required int UpdatedCount { get; init; }

    public required int UnchangedCount { get; init; }

    public required int ReactivatedCount { get; init; }
}
