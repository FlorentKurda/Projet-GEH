using Catalog.Sync.Worker.Configuration;
using Catalog.Sync.Worker.Errors;
using Catalog.Sync.Worker.Products;
using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker.Tests.Products;

public sealed class JsonProductSourceTests : IDisposable
{
    private readonly string _temporaryDirectory = Path.Combine(
        Path.GetTempPath(),
        $"catalog-sync-tests-{Guid.NewGuid():N}");

    public JsonProductSourceTests()
    {
        Directory.CreateDirectory(_temporaryDirectory);
    }

    [Fact]
    public async Task GetProductsAsync_LoadsTheSixtyFixtureProducts()
    {
        var fixturePath = Path.Combine(AppContext.BaseDirectory, "Fixtures", "products.json");
        var source = CreateSource(fixturePath);

        var products = await source.GetProductsAsync(CancellationToken.None);

        Assert.Equal(60, products.Count);
        Assert.Equal(60, products.Select(product => product.SourceId).Distinct().Count());
    }

    [Fact]
    public async Task GetProductsAsync_ResolvesRelativePathFromApplicationDirectory()
    {
        var source = CreateSource(Path.Combine("Fixtures", "products.json"));

        var products = await source.GetProductsAsync(CancellationToken.None);

        Assert.Equal(60, products.Count);
    }

    [Fact]
    public async Task GetProductsAsync_ThrowsClearErrorWhenFileDoesNotExist()
    {
        var missingPath = Path.Combine(_temporaryDirectory, "missing-products.json");
        var source = CreateSource(missingPath);

        var exception = await Assert.ThrowsAsync<ProductSourceException>(
            () => source.GetProductsAsync(CancellationToken.None));

        Assert.Contains("introuvable", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task GetProductsAsync_RejectsProductWithInvalidRequiredField()
    {
        var path = await WriteJsonAsync(
            """
            [
              {
                "sourceId": "   ",
                "reference": "REF-0001",
                "name": "Produit exemple"
              }
            ]
            """);
        var source = CreateSource(path);

        var exception = await Assert.ThrowsAsync<ProductValidationException>(
            () => source.GetProductsAsync(CancellationToken.None));

        Assert.Contains("SourceId", exception.Message, StringComparison.Ordinal);
    }

    [Fact]
    public async Task GetProductsAsync_RespectsCancellation()
    {
        var fixturePath = Path.Combine(AppContext.BaseDirectory, "Fixtures", "products.json");
        var source = CreateSource(fixturePath);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => source.GetProductsAsync(cancellation.Token));
    }

    [Fact]
    public async Task GetProductsAsync_AllowsEmptyArrayForServerSideGuardrail()
    {
        var source = CreateSource(await WriteJsonAsync("[]"));

        var products = await source.GetProductsAsync(CancellationToken.None);

        Assert.Empty(products);
    }

    [Fact]
    public async Task GetProductsAsync_RejectsDuplicateSourceIdIgnoringCase()
    {
        var path = await WriteJsonAsync(
            """
            [
              { "sourceId": "MOCK-0001", "reference": "REF-1", "name": "Produit 1" },
              { "sourceId": "mock-0001", "reference": "REF-2", "name": "Produit 2" }
            ]
            """);
        var source = CreateSource(path);

        var exception = await Assert.ThrowsAsync<ProductValidationException>(
            () => source.GetProductsAsync(CancellationToken.None));

        Assert.Contains("plusieurs fois", exception.Message, StringComparison.OrdinalIgnoreCase);
    }

    public void Dispose()
    {
        if (Directory.Exists(_temporaryDirectory))
        {
            Directory.Delete(_temporaryDirectory, recursive: true);
        }
    }

    private static JsonProductSource CreateSource(string path)
    {
        return new JsonProductSource(
            Options.Create(new ProductSourceOptions { JsonFilePath = path }),
            new ProductSyncItemValidator());
    }

    private async Task<string> WriteJsonAsync(string json)
    {
        var path = Path.Combine(_temporaryDirectory, $"{Guid.NewGuid():N}.json");
        await File.WriteAllTextAsync(path, json);
        return path;
    }
}
