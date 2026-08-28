namespace Catalog.Contracts;

public sealed record StartSyncRunRequest
{
    public required Guid RunId { get; init; }

    public int SchemaVersion { get; init; } = 2;

    public required int ExpectedProductCount { get; init; }

    public required int ExpectedBatchCount { get; init; }

    public required string Source { get; init; }

    public bool DryRun { get; init; }
}
