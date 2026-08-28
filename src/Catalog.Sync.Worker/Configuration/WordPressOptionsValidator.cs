using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker.Configuration;

public sealed class WordPressOptionsValidator : IValidateOptions<WordPressOptions>
{
    public ValidateOptionsResult Validate(string? name, WordPressOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        var failures = new List<string>();

        if (!Uri.TryCreate(options.BaseUrl, UriKind.Absolute, out var baseUri))
        {
            failures.Add("WordPress:BaseUrl doit être une URL absolue valide.");
        }
        else
        {
            ValidateBaseUri(baseUri, options, failures);
        }

        if (string.IsNullOrWhiteSpace(options.RunsEndpoint) ||
            !options.RunsEndpoint.StartsWith("/", StringComparison.Ordinal) ||
            options.RunsEndpoint.Contains('?') ||
            options.RunsEndpoint.Contains('#') ||
            options.RunsEndpoint.Contains("://", StringComparison.Ordinal))
        {
            failures.Add("WordPress:RunsEndpoint doit être un chemin relatif commençant par '/'.");
        }

        if (string.IsNullOrWhiteSpace(options.Username))
        {
            failures.Add("WordPress:Username est obligatoire.");
        }

        if (string.IsNullOrWhiteSpace(options.ApplicationPassword))
        {
            failures.Add("WordPress:ApplicationPassword est obligatoire.");
        }

        if (options.RequestTimeoutSeconds is < 1 or > 300)
        {
            failures.Add("WordPress:RequestTimeoutSeconds doit être compris entre 1 et 300.");
        }

        if (options.MaxRetryAttempts is < 1 or > 5)
        {
            failures.Add("WordPress:MaxRetryAttempts doit être compris entre 1 et 5.");
        }

        if (options.RetryBaseDelayMilliseconds is < 1 or > 10_000)
        {
            failures.Add(
                "WordPress:RetryBaseDelayMilliseconds doit être compris entre 1 et 10000.");
        }

        return failures.Count == 0
            ? ValidateOptionsResult.Success
            : ValidateOptionsResult.Fail(failures);
    }

    private static void ValidateBaseUri(
        Uri baseUri,
        WordPressOptions options,
        ICollection<string> failures)
    {
        if (!string.IsNullOrEmpty(baseUri.UserInfo))
        {
            failures.Add("WordPress:BaseUrl ne doit contenir aucun identifiant.");
        }

        if (!string.IsNullOrEmpty(baseUri.Query) || !string.IsNullOrEmpty(baseUri.Fragment))
        {
            failures.Add("WordPress:BaseUrl ne doit contenir ni requête ni fragment.");
        }

        if (string.Equals(baseUri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        if (!string.Equals(baseUri.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase))
        {
            failures.Add("WordPress:BaseUrl doit utiliser HTTPS.");
            return;
        }

        if (!options.AllowInsecureHttpForLocalDevelopment || !baseUri.IsLoopback)
        {
            failures.Add(
                "HTTP non chiffré est autorisé uniquement pour une URL locale et lorsque " +
                "WordPress:AllowInsecureHttpForLocalDevelopment vaut true.");
        }
    }
}
