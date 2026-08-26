namespace Catalog.Sync.Worker.Configuration;

public sealed class SyncOptions
{
    public const string SectionName = "Sync";

    public int IntervalMinutes { get; set; } = 15;
}
