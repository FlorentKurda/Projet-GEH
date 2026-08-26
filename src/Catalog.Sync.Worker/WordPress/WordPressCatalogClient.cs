using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using Catalog.Contracts;
using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Configuration;
using Catalog.Sync.Worker.Errors;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker.WordPress;

public sealed class WordPressCatalogClient : IWordPressCatalogClient
{
    public const string HttpClientName = "WordPressCatalog";

    private const int MaximumErrorBodyCharacters = 4_096;
    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web);

    private readonly IHttpClientFactory _httpClientFactory;
    private readonly WordPressOptions _options;
    private readonly ILogger<WordPressCatalogClient> _logger;

    public WordPressCatalogClient(
        IHttpClientFactory httpClientFactory,
        IOptions<WordPressOptions> options,
        ILogger<WordPressCatalogClient> logger)
    {
        _httpClientFactory = httpClientFactory ??
            throw new ArgumentNullException(nameof(httpClientFactory));
        ArgumentNullException.ThrowIfNull(options);
        _options = options.Value;
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    public async Task<SyncResult> SynchronizeAsync(
        ProductSyncRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        cancellationToken.ThrowIfCancellationRequested();

        using var httpClient = _httpClientFactory.CreateClient(HttpClientName);
        using var httpRequest = CreateRequest(request);

        _logger.LogInformation(
            "Envoi de la synchronisation {RunId} contenant {ProductCount} produits vers WordPress.",
            request.RunId,
            request.Products.Count);

        try
        {
            using var response = await httpClient.SendAsync(
                httpRequest,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);

            if (!response.IsSuccessStatusCode)
            {
                var responseBody = await ReadErrorBodyAsync(response, cancellationToken);
                var detail = string.IsNullOrWhiteSpace(responseBody)
                    ? string.Empty
                    : $" Réponse : {RedactSecrets(responseBody)}";

                throw new WordPressCatalogException(
                    $"WordPress a refusé la synchronisation avec le code HTTP " +
                    $"{(int)response.StatusCode}.{detail}");
            }

            var result = await response.Content.ReadFromJsonAsync<SyncResult>(
                SerializerOptions,
                cancellationToken);

            ValidateResponse(result, request);
            return result!;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException exception)
        {
            throw new WordPressCatalogException(
                "La requête de synchronisation WordPress a dépassé son délai maximal.",
                exception);
        }
        catch (WordPressCatalogException)
        {
            throw;
        }
        catch (HttpRequestException exception)
        {
            throw new WordPressCatalogException(
                $"La synchronisation WordPress a échoué à cause d'une erreur réseau : " +
                $"{RedactSecrets(exception.Message)}",
                exception);
        }
        catch (JsonException exception)
        {
            throw new WordPressCatalogException(
                "WordPress a renvoyé une réponse JSON invalide.",
                exception);
        }
        catch (NotSupportedException exception)
        {
            throw new WordPressCatalogException(
                "WordPress a renvoyé une réponse dans un format non pris en charge.",
                exception);
        }
    }

    private HttpRequestMessage CreateRequest(ProductSyncRequest request)
    {
        var credentials = Convert.ToBase64String(
            Encoding.UTF8.GetBytes($"{_options.Username}:{_options.ApplicationPassword}"));

        var httpRequest = new HttpRequestMessage(HttpMethod.Post, _options.SyncEndpoint)
        {
            Content = JsonContent.Create(request, options: SerializerOptions),
        };
        httpRequest.Headers.Authorization = new AuthenticationHeaderValue("Basic", credentials);

        return httpRequest;
    }

    private static void ValidateResponse(SyncResult? result, ProductSyncRequest request)
    {
        if (result is null)
        {
            throw new WordPressCatalogException("WordPress a renvoyé une réponse vide.");
        }

        if (result.RunId != request.RunId)
        {
            throw new WordPressCatalogException(
                "Le runId renvoyé par WordPress ne correspond pas à la synchronisation envoyée.");
        }

        if (!string.Equals(result.Status, "success", StringComparison.Ordinal))
        {
            throw new WordPressCatalogException(
                "WordPress n'a pas confirmé le succès de la synchronisation.");
        }

        if (result.ReceivedCount != request.Products.Count ||
            result.InsertedCount < 0 ||
            result.UpdatedCount < 0)
        {
            throw new WordPressCatalogException(
                "Les compteurs renvoyés par WordPress sont incohérents.");
        }
    }

    private static async Task<string> ReadErrorBodyAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        if (response.StatusCode == HttpStatusCode.NoContent)
        {
            return string.Empty;
        }

        await using var responseStream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var reader = new StreamReader(
            responseStream,
            Encoding.UTF8,
            detectEncodingFromByteOrderMarks: true,
            bufferSize: 1_024,
            leaveOpen: false);

        var buffer = new char[MaximumErrorBodyCharacters];
        var charactersRead = await reader.ReadBlockAsync(buffer, cancellationToken);
        var suffix = charactersRead == MaximumErrorBodyCharacters ? "…" : string.Empty;

        return new string(buffer, 0, charactersRead) + suffix;
    }

    private string RedactSecrets(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return value;
        }

        var redacted = value;
        var combinedCredentials = $"{_options.Username}:{_options.ApplicationPassword}";
        var encodedCredentials = Convert.ToBase64String(Encoding.UTF8.GetBytes(combinedCredentials));

        redacted = Redact(redacted, encodedCredentials);
        redacted = Redact(redacted, combinedCredentials);
        redacted = Redact(redacted, _options.ApplicationPassword);
        redacted = Redact(redacted, _options.Username);

        return redacted;
    }

    private static string Redact(string value, string secret)
    {
        return string.IsNullOrEmpty(secret)
            ? value
            : value.Replace(secret, "[REDACTED]", StringComparison.OrdinalIgnoreCase);
    }
}
