namespace Catalog.Sync.Worker.Configuration;

public sealed class WordPressOptions
{
    public const string SectionName = "WordPress";

    public string BaseUrl { get; set; } = string.Empty;

    public string SyncEndpoint { get; set; } = "/wp-json/catalog-sync/v1/products";

    public string Username { get; set; } = string.Empty;

    public string ApplicationPassword { get; set; } = string.Empty;

    public int RequestTimeoutSeconds { get; set; } = 60;

    public bool AllowInsecureHttpForLocalDevelopment { get; set; }
}
