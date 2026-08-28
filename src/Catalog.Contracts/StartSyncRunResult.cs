namespace Catalog.Contracts;

public sealed record StartSyncRunResult
{
    public required Guid RunId { get; init; }

    public required string Status { get; init; }
}
