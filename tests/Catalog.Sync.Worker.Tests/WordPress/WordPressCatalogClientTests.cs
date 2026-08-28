using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Catalog.Contracts;
using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Configuration;
using Catalog.Sync.Worker.Errors;
using Catalog.Sync.Worker.WordPress;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker.Tests.WordPress;

public sealed class WordPressCatalogClientTests
{
    private const string Username = "catalog_sync";
    private const string ApplicationPassword = "test-only-app-password";
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    [Fact]
    public async Task StartRunAsync_SerializesVersionTwoRunIdAndAddsBasicAuthentication()
    {
        var request = CreateStartRequest();
        AuthenticationHeaderValue? authorization = null;
        string? body = null;
        var handler = new StubHttpMessageHandler(async (httpRequest, cancellationToken) =>
        {
            authorization = httpRequest.Headers.Authorization;
            body = await httpRequest.Content!.ReadAsStringAsync(cancellationToken);
            return JsonResponse(new StartSyncRunResult
            {
                RunId = request.RunId,
                Status = "started",
            }, HttpStatusCode.Created);
        });
        var client = CreateClient(handler);

        var result = await client.StartRunAsync(request, CancellationToken.None);

        Assert.Equal(request.RunId, result.RunId);
        Assert.Equal("Basic", authorization!.Scheme);
        Assert.Equal(
            Convert.ToBase64String(Encoding.UTF8.GetBytes($"{Username}:{ApplicationPassword}")),
            authorization.Parameter);
        using var document = JsonDocument.Parse(body!);
        Assert.Equal(request.RunId, document.RootElement.GetProperty("runId").GetGuid());
        Assert.Equal(2, document.RootElement.GetProperty("schemaVersion").GetInt32());
        Assert.Equal(60, document.RootElement.GetProperty("expectedProductCount").GetInt32());
        Assert.Equal(3, document.RootElement.GetProperty("expectedBatchCount").GetInt32());
    }

    [Fact]
    public async Task StartRunAsync_RejectsDifferentReturnedRunId()
    {
        var handler = new StubHttpMessageHandler((_, _) => Task.FromResult(
            JsonResponse(new StartSyncRunResult
            {
                RunId = Guid.Parse("d410be31-1a9c-4d32-a388-1f59c9a47542"),
                Status = "started",
            }, HttpStatusCode.Created)));
        var client = CreateClient(handler);

        await Assert.ThrowsAsync<WordPressCatalogException>(
            () => client.StartRunAsync(CreateStartRequest(), CancellationToken.None));
    }

    [Fact]
    public async Task SendBatchAsync_UsesRunEndpointAndSerializesContentHash()
    {
        var runId = CreateStartRequest().RunId;
        Uri? uri = null;
        string? body = null;
        var request = CreateBatchRequest();
        var handler = new StubHttpMessageHandler(async (httpRequest, cancellationToken) =>
        {
            uri = httpRequest.RequestUri;
            body = await httpRequest.Content!.ReadAsStringAsync(cancellationToken);
            return JsonResponse(CreateBatchResult(runId, request));
        });
        var client = CreateClient(handler);

        var result = await client.SendBatchAsync(runId, request, CancellationToken.None);

        Assert.EndsWith($"/runs/{runId:D}/products", uri!.AbsolutePath, StringComparison.Ordinal);
        using var document = JsonDocument.Parse(body!);
        Assert.Equal(1, document.RootElement.GetProperty("batchNumber").GetInt32());
        Assert.Equal(
            new string('a', 64),
            document.RootElement.GetProperty("products")[0].GetProperty("contentHash").GetString());
        Assert.Equal(1, result.UnchangedCount);
    }

    [Fact]
    public async Task CompleteRunAsync_ReturnsConsistentResult()
    {
        var runId = CreateStartRequest().RunId;
        HttpContent? content = new StringContent("unexpected");
        var handler = new StubHttpMessageHandler((request, _) =>
        {
            content = request.Content;
            return Task.FromResult(JsonResponse(CreateCompletedResult(runId)));
        });
        var client = CreateClient(handler);

        var result = await client.CompleteRunAsync(runId, CancellationToken.None);

        Assert.Null(content);
        Assert.Equal("completed", result.Status);
        Assert.Equal(1, result.UnchangedCount);
    }

    [Fact]
    public async Task StartRunAsync_RetriesTransientStatusWithExactSamePayload()
    {
        var request = CreateStartRequest();
        var bodies = new List<string>();
        var calls = 0;
        var handler = new StubHttpMessageHandler(async (httpRequest, cancellationToken) =>
        {
            calls++;
            bodies.Add(await httpRequest.Content!.ReadAsStringAsync(cancellationToken));
            return calls < 3
                ? new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)
                : JsonResponse(new StartSyncRunResult
                {
                    RunId = request.RunId,
                    Status = "started",
                }, HttpStatusCode.Created);
        });
        var delay = new StubRetryDelay();
        var client = CreateClient(handler, delay);

        await client.StartRunAsync(request, CancellationToken.None);

        Assert.Equal(3, calls);
        Assert.Equal(2, delay.Delays.Count);
        Assert.All(bodies, body => Assert.Equal(bodies[0], body));
        Assert.All(
            bodies,
            body => Assert.Contains(request.RunId.ToString(), body, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public async Task StartRunAsync_RetriesTemporaryNetworkFailure()
    {
        var request = CreateStartRequest();
        var calls = 0;
        var handler = new StubHttpMessageHandler((_, _) =>
        {
            calls++;
            if (calls == 1)
            {
                throw new HttpRequestException("Temporary test failure.");
            }

            return Task.FromResult(JsonResponse(new StartSyncRunResult
            {
                RunId = request.RunId,
                Status = "started",
            }, HttpStatusCode.Created));
        });
        var delay = new StubRetryDelay();
        var client = CreateClient(handler, delay);

        await client.StartRunAsync(request, CancellationToken.None);

        Assert.Equal(2, calls);
        Assert.Single(delay.Delays);
    }

    [Fact]
    public async Task StartRunAsync_RetriesInternalTimeout()
    {
        var request = CreateStartRequest();
        var calls = 0;
        var handler = new StubHttpMessageHandler((_, _) =>
        {
            calls++;
            if (calls == 1)
            {
                return Task.FromException<HttpResponseMessage>(
                    new TaskCanceledException("Simulated HTTP timeout."));
            }

            return Task.FromResult(JsonResponse(new StartSyncRunResult
            {
                RunId = request.RunId,
                Status = "started",
            }, HttpStatusCode.Created));
        });
        var delay = new StubRetryDelay();
        var client = CreateClient(handler, delay);

        await client.StartRunAsync(request, CancellationToken.None);

        Assert.Equal(2, calls);
        Assert.Single(delay.Delays);
    }

    [Theory]
    [InlineData(HttpStatusCode.BadRequest)]
    [InlineData(HttpStatusCode.Unauthorized)]
    [InlineData(HttpStatusCode.Conflict)]
    public async Task StartRunAsync_DoesNotRetryPermanentClientError(HttpStatusCode statusCode)
    {
        var calls = 0;
        var handler = new StubHttpMessageHandler((_, _) =>
        {
            calls++;
            return Task.FromResult(new HttpResponseMessage(statusCode)
            {
                Content = new StringContent("{\"code\":\"permanent_error\"}"),
            });
        });
        var delay = new StubRetryDelay();
        var client = CreateClient(handler, delay);

        var exception = await Assert.ThrowsAsync<WordPressCatalogException>(
            () => client.StartRunAsync(CreateStartRequest(), CancellationToken.None));

        Assert.Equal(1, calls);
        Assert.Empty(delay.Delays);
        Assert.Contains(((int)statusCode).ToString(), exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task StartRunAsync_NeverIncludesPasswordOrCredentialsInFailureMessage()
    {
        var encoded = Convert.ToBase64String(
            Encoding.UTF8.GetBytes($"{Username}:{ApplicationPassword}"));
        var unsafeBody = $"{Username};{ApplicationPassword};{Username}:{ApplicationPassword};{encoded}";
        var handler = new StubHttpMessageHandler((_, _) => Task.FromResult(
            new HttpResponseMessage(HttpStatusCode.BadRequest)
            {
                Content = new StringContent(unsafeBody),
            }));
        var client = CreateClient(handler);

        var exception = await Assert.ThrowsAsync<WordPressCatalogException>(
            () => client.StartRunAsync(CreateStartRequest(), CancellationToken.None));

        Assert.DoesNotContain(ApplicationPassword, exception.Message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(encoded, exception.Message, StringComparison.Ordinal);
        Assert.DoesNotContain(Username, exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task StartRunAsync_RespectsCallerCancellationWithoutRetry()
    {
        var calls = 0;
        var handler = new StubHttpMessageHandler(async (_, cancellationToken) =>
        {
            calls++;
            await Task.Delay(TimeSpan.FromMinutes(1), cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK);
        });
        var delay = new StubRetryDelay();
        var client = CreateClient(handler, delay);
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => client.StartRunAsync(CreateStartRequest(), cancellation.Token));

        Assert.Equal(1, calls);
        Assert.Empty(delay.Delays);
    }

    private static WordPressCatalogClient CreateClient(
        HttpMessageHandler handler,
        IRetryDelay? retryDelay = null)
    {
        var options = new WordPressOptions
        {
            BaseUrl = "http://localhost:8080",
            RunsEndpoint = "/wp-json/catalog-sync/v1/runs",
            Username = Username,
            ApplicationPassword = ApplicationPassword,
            RequestTimeoutSeconds = 60,
            MaxRetryAttempts = 3,
            RetryBaseDelayMilliseconds = 1,
            AllowInsecureHttpForLocalDevelopment = true,
        };

        return new WordPressCatalogClient(
            new StubHttpClientFactory(handler, options),
            retryDelay ?? new StubRetryDelay(),
            Options.Create(options),
            NullLogger<WordPressCatalogClient>.Instance);
    }

    private static StartSyncRunRequest CreateStartRequest() => new()
    {
        RunId = Guid.Parse("71c7ea7a-55c4-4fc0-a721-6ac4cd8e3280"),
        ExpectedProductCount = 60,
        ExpectedBatchCount = 3,
        Source = "json-fixture",
        DryRun = false,
    };

    private static ProductSyncBatchRequest CreateBatchRequest() => new()
    {
        BatchNumber = 1,
        Products =
        [
            new ProductSyncPayloadItem
            {
                SourceId = "MOCK-0001",
                Reference = "REF-0001",
                Name = "Produit exemple",
                ContentHash = new string('a', 64),
            },
        ],
    };

    private static ProductSyncBatchResult CreateBatchResult(
        Guid runId,
        ProductSyncBatchRequest request) => new()
    {
        RunId = runId,
        BatchNumber = request.BatchNumber,
        Status = "running",
        Replayed = false,
        ReceivedCount = request.Products.Count,
        InsertedCount = 0,
        UpdatedCount = 0,
        UnchangedCount = request.Products.Count,
        ReactivatedCount = 0,
    };

    private static SyncResult CreateCompletedResult(Guid runId) => new()
    {
        RunId = runId,
        Status = "completed",
        ReceivedCount = 1,
        InsertedCount = 0,
        UpdatedCount = 0,
        UnchangedCount = 1,
        ReactivatedCount = 0,
        DeactivatedCount = 0,
        CandidateDeactivationCount = 0,
        ActiveBeforeCount = 1,
        DeactivationPercentage = 0,
        GuardrailStatus = "ok",
        DryRun = false,
    };

    private static HttpResponseMessage JsonResponse<T>(
        T value,
        HttpStatusCode statusCode = HttpStatusCode.OK) => new(statusCode)
    {
        Content = new StringContent(
            JsonSerializer.Serialize(value, JsonOptions),
            Encoding.UTF8,
            "application/json"),
    };

    private sealed class StubRetryDelay : IRetryDelay
    {
        public List<TimeSpan> Delays { get; } = [];

        public Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Delays.Add(delay);
            return Task.CompletedTask;
        }
    }

    private sealed class StubHttpClientFactory(
        HttpMessageHandler handler,
        WordPressOptions options) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name)
        {
            Assert.Equal(WordPressCatalogClient.HttpClientName, name);
            return new HttpClient(handler, disposeHandler: false)
            {
                BaseAddress = new Uri(options.BaseUrl),
                Timeout = TimeSpan.FromSeconds(options.RequestTimeoutSeconds),
            };
        }
    }

    private sealed class StubHttpMessageHandler(
        Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> handler)
        : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => handler(request, cancellationToken);
    }
}
