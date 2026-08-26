namespace Catalog.Sync.Worker.Configuration;

public sealed class ProductSourceOptions
{
    public const string SectionName = "ProductSource";

    public string JsonFilePath { get; set; } = string.Empty;
}
