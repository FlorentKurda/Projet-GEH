namespace Catalog.Sync.Worker.Configuration;

public sealed class WordPressOptions
{
    public const string SectionName = "WordPress";

    public string BaseUrl { get; set; } = string.Empty;

    public string RunsEndpoint { get; set; } = "/wp-json/catalog-sync/v1/runs";

    // Conservé pour que les anciens fichiers locaux Lot 1 puissent rester en place.
    // Le protocole Lot 2 utilise exclusivement RunsEndpoint.
    public string? SyncEndpoint { get; set; }

    public string Username { get; set; } = string.Empty;

    public string ApplicationPassword { get; set; } = string.Empty;

    public int RequestTimeoutSeconds { get; set; } = 60;

    public int MaxRetryAttempts { get; set; } = 3;

    public int RetryBaseDelayMilliseconds { get; set; } = 200;

    public bool AllowInsecureHttpForLocalDevelopment { get; set; }
}
