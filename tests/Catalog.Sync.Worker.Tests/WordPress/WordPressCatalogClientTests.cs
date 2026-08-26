using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Catalog.Contracts;
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

    [Fact]
    public async Task SynchronizeAsync_SerializesPayloadAndAddsBasicAuthentication()
    {
        var request = CreateRequest();
        AuthenticationHeaderValue? capturedAuthorization = null;
        string? capturedBody = null;
        var handler = new StubHttpMessageHandler(async (httpRequest, cancellationToken) =>
        {
            capturedAuthorization = httpRequest.Headers.Authorization;
            capturedBody = await httpRequest.Content!.ReadAsStringAsync(cancellationToken);
            return CreateSuccessResponse(request);
        });
        var client = CreateClient(handler);

        await client.SynchronizeAsync(request, CancellationToken.None);

        Assert.NotNull(capturedAuthorization);
        Assert.Equal("Basic", capturedAuthorization.Scheme);
        Assert.Equal(
            Convert.ToBase64String(Encoding.UTF8.GetBytes($"{Username}:{ApplicationPassword}")),
            capturedAuthorization.Parameter);

        using var document = JsonDocument.Parse(Assert.IsType<string>(capturedBody));
        var root = document.RootElement;
        Assert.Equal(1, root.GetProperty("schemaVersion").GetInt32());
        Assert.Equal(request.RunId, root.GetProperty("runId").GetGuid());
        Assert.Equal(1, root.GetProperty("products").GetArrayLength());
        Assert.Equal(
            "MOCK-0001",
            root.GetProperty("products")[0].GetProperty("sourceId").GetString());
    }

    [Fact]
    public async Task SynchronizeAsync_ReturnsSuccessfulResponse()
    {
        var request = CreateRequest();
        var handler = new StubHttpMessageHandler(
            (_, _) => Task.FromResult(CreateSuccessResponse(request)));
        var client = CreateClient(handler);

        var result = await client.SynchronizeAsync(request, CancellationToken.None);

        Assert.Equal(request.RunId, result.RunId);
        Assert.Equal("success", result.Status);
        Assert.Equal(1, result.ReceivedCount);
        Assert.Equal(1, result.InsertedCount);
        Assert.Equal(0, result.UpdatedCount);
    }

    [Fact]
    public async Task SynchronizeAsync_ThrowsClearErrorForHttpFailure()
    {
        var handler = new StubHttpMessageHandler(
            (_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadRequest)
            {
                Content = new StringContent(
                    "{\"code\":\"catalog_invalid_payload\"}",
                    Encoding.UTF8,
                    "application/json"),
            }));
        var client = CreateClient(handler);

        var exception = await Assert.ThrowsAsync<WordPressCatalogException>(
            () => client.SynchronizeAsync(CreateRequest(), CancellationToken.None));

        Assert.Contains("400", exception.Message, StringComparison.Ordinal);
        Assert.Contains("catalog_invalid_payload", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task SynchronizeAsync_NeverIncludesPasswordOrCredentialsInFailureMessage()
    {
        var encodedCredentials = Convert.ToBase64String(
            Encoding.UTF8.GetBytes($"{Username}:{ApplicationPassword}"));
        var unsafeResponse =
            $"username={Username}; password={ApplicationPassword}; " +
            $"credentials={Username}:{ApplicationPassword}; token={encodedCredentials}";
        var handler = new StubHttpMessageHandler(
            (_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.InternalServerError)
            {
                Content = new StringContent(unsafeResponse, Encoding.UTF8, "text/plain"),
            }));
        var client = CreateClient(handler);

        var exception = await Assert.ThrowsAsync<WordPressCatalogException>(
            () => client.SynchronizeAsync(CreateRequest(), CancellationToken.None));

        Assert.DoesNotContain(ApplicationPassword, exception.Message, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(encodedCredentials, exception.Message, StringComparison.Ordinal);
        Assert.DoesNotContain(Username, exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task SynchronizeAsync_RespectsCancellation()
    {
        var handler = new StubHttpMessageHandler(async (_, cancellationToken) =>
        {
            await Task.Delay(TimeSpan.FromMinutes(1), cancellationToken);
            return new HttpResponseMessage(HttpStatusCode.OK);
        });
        var client = CreateClient(handler);
        using var cancellation = new CancellationTokenSource(TimeSpan.FromMilliseconds(50));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => client.SynchronizeAsync(CreateRequest(), cancellation.Token));
    }

    private static WordPressCatalogClient CreateClient(HttpMessageHandler handler)
    {
        var options = new WordPressOptions
        {
            BaseUrl = "http://localhost:8080",
            SyncEndpoint = "/wp-json/catalog-sync/v1/products",
            Username = Username,
            ApplicationPassword = ApplicationPassword,
            RequestTimeoutSeconds = 60,
            AllowInsecureHttpForLocalDevelopment = true,
        };

        return new WordPressCatalogClient(
            new StubHttpClientFactory(handler, options),
            Options.Create(options),
            NullLogger<WordPressCatalogClient>.Instance);
    }

    private static ProductSyncRequest CreateRequest()
    {
        return new ProductSyncRequest
        {
            SchemaVersion = 1,
            RunId = Guid.Parse("71c7ea7a-55c4-4fc0-a721-6ac4cd8e3280"),
            SentAtUtc = DateTimeOffset.Parse("2026-08-26T10:00:00Z"),
            Products =
            [
                new ProductSyncItem
                {
                    SourceId = "MOCK-0001",
                    Reference = "REF-0001",
                    Name = "Produit exemple",
                    ShortDescription = "Description courte",
                    FamilyCode = "FAM-A",
                    FamilyLabel = "Famille A",
                    Brand = "Marque A",
                    SourceUpdatedAtUtc = DateTimeOffset.Parse("2026-08-20T08:00:00Z"),
                },
            ],
        };
    }

    private static HttpResponseMessage CreateSuccessResponse(ProductSyncRequest request)
    {
        var json = JsonSerializer.Serialize(
            new SyncResult
            {
                RunId = request.RunId,
                Status = "success",
                ReceivedCount = request.Products.Count,
                InsertedCount = request.Products.Count,
                UpdatedCount = 0,
            },
            new JsonSerializerOptions(JsonSerializerDefaults.Web));

        return new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };
    }

    private sealed class StubHttpClientFactory : IHttpClientFactory
    {
        private readonly HttpMessageHandler _handler;
        private readonly WordPressOptions _options;

        public StubHttpClientFactory(HttpMessageHandler handler, WordPressOptions options)
        {
            _handler = handler;
            _options = options;
        }

        public HttpClient CreateClient(string name)
        {
            Assert.Equal(WordPressCatalogClient.HttpClientName, name);
            return new HttpClient(_handler, disposeHandler: false)
            {
                BaseAddress = new Uri(_options.BaseUrl),
                Timeout = TimeSpan.FromSeconds(_options.RequestTimeoutSeconds),
            };
        }
    }

    private sealed class StubHttpMessageHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> _handler;

        public StubHttpMessageHandler(
            Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> handler)
        {
            _handler = handler;
        }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            return _handler(request, cancellationToken);
        }
    }
}
