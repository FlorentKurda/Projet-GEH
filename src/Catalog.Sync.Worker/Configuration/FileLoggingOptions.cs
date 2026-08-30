namespace Catalog.Sync.Worker.Configuration;

public sealed class FileLoggingOptions
{
    public const string SectionName = "FileLogging";

    public bool Enabled { get; set; } = true;

    public string DirectoryPath { get; set; } = "logs";

    public int RetentionDays { get; set; } = 30;
}
