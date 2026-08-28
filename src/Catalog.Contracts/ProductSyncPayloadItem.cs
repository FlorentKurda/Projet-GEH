namespace Catalog.Contracts;

public sealed record ProductSyncPayloadItem
{
    public required string SourceId { get; init; }

    public required string Reference { get; init; }

    public required string Name { get; init; }

    public string? ShortDescription { get; init; }

    public string? FamilyCode { get; init; }

    public string? FamilyLabel { get; init; }

    public string? Brand { get; init; }

    public DateTimeOffset? SourceUpdatedAtUtc { get; init; }

    public required string ContentHash { get; init; }
}
