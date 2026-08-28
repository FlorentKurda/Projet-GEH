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
    private static readonly HashSet<HttpStatusCode> TransientStatusCodes =
    [
        HttpStatusCode.RequestTimeout,
        HttpStatusCode.TooManyRequests,
        HttpStatusCode.InternalServerError,
        HttpStatusCode.BadGateway,
        HttpStatusCode.ServiceUnavailable,
        HttpStatusCode.GatewayTimeout,
    ];

    private readonly IHttpClientFactory _httpClientFactory;
    private readonly IRetryDelay _retryDelay;
    private readonly WordPressOptions _options;
    private readonly ILogger<WordPressCatalogClient> _logger;

    public WordPressCatalogClient(
        IHttpClientFactory httpClientFactory,
        IRetryDelay retryDelay,
        IOptions<WordPressOptions> options,
        ILogger<WordPressCatalogClient> logger)
    {
        _httpClientFactory = httpClientFactory ??
            throw new ArgumentNullException(nameof(httpClientFactory));
        _retryDelay = retryDelay ?? throw new ArgumentNullException(nameof(retryDelay));
        ArgumentNullException.ThrowIfNull(options);
        _options = options.Value;
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    public async Task<StartSyncRunResult> StartRunAsync(
        StartSyncRunRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var result = await SendAsync<StartSyncRunResult>(
            _options.RunsEndpoint,
            request,
            cancellationToken);

        if (result.RunId != request.RunId ||
            !string.Equals(result.Status, "started", StringComparison.Ordinal))
        {
            throw new WordPressCatalogException(
                "WordPress n'a pas confirmé le démarrage du run.");
        }

        return result;
    }

    public async Task<ProductSyncBatchResult> SendBatchAsync(
        Guid runId,
        ProductSyncBatchRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        var endpoint = $"{_options.RunsEndpoint.TrimEnd('/')}/{runId:D}/products";
        var result = await SendAsync<ProductSyncBatchResult>(endpoint, request, cancellationToken);

        if (result.RunId != runId ||
            result.BatchNumber != request.BatchNumber ||
            !string.Equals(result.Status, "running", StringComparison.Ordinal) ||
            result.ReceivedCount != request.Products.Count ||
            HasNegativeBatchCounter(result) ||
            result.ReceivedCount != result.InsertedCount + result.UpdatedCount +
                result.UnchangedCount + result.ReactivatedCount)
        {
            throw new WordPressCatalogException(
                "Les informations de batch renvoyées par WordPress sont incohérentes.");
        }

        return result;
    }

    public async Task<SyncResult> CompleteRunAsync(
        Guid runId,
        CancellationToken cancellationToken)
    {
        var endpoint = $"{_options.RunsEndpoint.TrimEnd('/')}/{runId:D}/complete";
        var result = await SendAsync<SyncResult>(endpoint, payload: null, cancellationToken);

        if (result.RunId != runId ||
            !string.Equals(result.Status, "completed", StringComparison.Ordinal) ||
            HasNegativeRunCounter(result) ||
            result.ReceivedCount != result.InsertedCount + result.UpdatedCount +
                result.UnchangedCount + result.ReactivatedCount)
        {
            throw new WordPressCatalogException(
                "Les compteurs de finalisation renvoyés par WordPress sont incohérents.");
        }

        return result;
    }

    private async Task<TResponse> SendAsync<TResponse>(
        string endpoint,
        object? payload,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var httpClient = _httpClientFactory.CreateClient(HttpClientName);

        for (var attempt = 1; attempt <= _options.MaxRetryAttempts; attempt++)
        {
            try
            {
                using var request = CreateRequest(endpoint, payload);
                using var response = await httpClient.SendAsync(request, cancellationToken);

                if (TransientStatusCodes.Contains(response.StatusCode) &&
                    attempt < _options.MaxRetryAttempts)
                {
                    _logger.LogWarning(
                        "WordPress a répondu HTTP {StatusCode}; nouvelle tentative {NextAttempt}/{MaximumAttempts}.",
                        (int)response.StatusCode,
                        attempt + 1,
                        _options.MaxRetryAttempts);
                    await DelayBeforeRetryAsync(attempt, cancellationToken);
                    continue;
                }

                if (!response.IsSuccessStatusCode)
                {
                    throw await CreateHttpFailureAsync(response, cancellationToken);
                }

                var result = await response.Content.ReadFromJsonAsync<TResponse>(
                    SerializerOptions,
                    cancellationToken);
                return result ?? throw new WordPressCatalogException(
                    "WordPress a renvoyé une réponse vide.");
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (OperationCanceledException)
                when (attempt < _options.MaxRetryAttempts)
            {
                _logger.LogWarning(
                    "Timeout WordPress; nouvelle tentative {NextAttempt}/{MaximumAttempts}.",
                    attempt + 1,
                    _options.MaxRetryAttempts);
                await DelayBeforeRetryAsync(attempt, cancellationToken);
            }
            catch (HttpRequestException exception)
                when (attempt < _options.MaxRetryAttempts)
            {
                _logger.LogWarning(
                    "Erreur réseau WordPress ({ErrorType}); nouvelle tentative {NextAttempt}/{MaximumAttempts}.",
                    exception.GetType().Name,
                    attempt + 1,
                    _options.MaxRetryAttempts);
                await DelayBeforeRetryAsync(attempt, cancellationToken);
            }
            catch (OperationCanceledException exception)
            {
                throw new WordPressCatalogException(
                    "La requête WordPress a dépassé son délai maximal après les nouvelles tentatives.",
                    exception);
            }
            catch (HttpRequestException exception)
            {
                throw new WordPressCatalogException(
                    $"La requête WordPress a échoué après les nouvelles tentatives : " +
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

        throw new WordPressCatalogException("La requête WordPress a échoué.");
    }

    private HttpRequestMessage CreateRequest(string endpoint, object? payload)
    {
        var credentials = Convert.ToBase64String(
            Encoding.UTF8.GetBytes($"{_options.Username}:{_options.ApplicationPassword}"));
        var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        if (payload is not null)
        {
            request.Content = JsonContent.Create(payload, options: SerializerOptions);
        }

        request.Headers.Authorization = new AuthenticationHeaderValue("Basic", credentials);
        return request;
    }

    private Task DelayBeforeRetryAsync(int failedAttempt, CancellationToken cancellationToken)
    {
        var factor = Math.Pow(2, failedAttempt - 1);
        var milliseconds = Math.Min(
            _options.RetryBaseDelayMilliseconds * factor,
            10_000d);
        return _retryDelay.DelayAsync(TimeSpan.FromMilliseconds(milliseconds), cancellationToken);
    }

    private async Task<WordPressCatalogException> CreateHttpFailureAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        var responseBody = await ReadErrorBodyAsync(response, cancellationToken);
        var detail = string.IsNullOrWhiteSpace(responseBody)
            ? string.Empty
            : $" Réponse : {RedactSecrets(responseBody)}";
        return new WordPressCatalogException(
            $"WordPress a refusé la requête avec le code HTTP {(int)response.StatusCode}.{detail}");
    }

    private static bool HasNegativeBatchCounter(ProductSyncBatchResult result) =>
        result.InsertedCount < 0 ||
        result.UpdatedCount < 0 ||
        result.UnchangedCount < 0 ||
        result.ReactivatedCount < 0;

    private static bool HasNegativeRunCounter(SyncResult result) =>
        result.ReceivedCount < 0 ||
        result.InsertedCount < 0 ||
        result.UpdatedCount < 0 ||
        result.UnchangedCount < 0 ||
        result.ReactivatedCount < 0 ||
        result.DeactivatedCount < 0 ||
        result.CandidateDeactivationCount < 0 ||
        result.ActiveBeforeCount < 0 ||
        result.DeactivationPercentage < 0;

    private static async Task<string> ReadErrorBodyAsync(
        HttpResponseMessage response,
        CancellationToken cancellationToken)
    {
        if (response.StatusCode == HttpStatusCode.NoContent)
        {
            return string.Empty;
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        using var reader = new StreamReader(
            stream,
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

        var combined = $"{_options.Username}:{_options.ApplicationPassword}";
        var encoded = Convert.ToBase64String(Encoding.UTF8.GetBytes(combined));
        return Redact(
            Redact(
                Redact(
                    Redact(value, encoded),
                    combined),
                _options.ApplicationPassword),
            _options.Username);
    }

    private static string Redact(string value, string secret) =>
        string.IsNullOrEmpty(secret)
            ? value
            : value.Replace(secret, "[REDACTED]", StringComparison.OrdinalIgnoreCase);
}
