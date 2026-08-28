using Catalog.Contracts;
using Catalog.Sync.Worker.Products;

namespace Catalog.Sync.Worker.Tests.Products;

public sealed class ProductContentHasherTests
{
    [Fact]
    public void ComputeHash_UsesStableCanonicalSha256()
    {
        var product = new ProductSyncItem
        {
            SourceId = "A",
            Reference = "B",
            Name = "C",
        };

        var hash = ProductContentHasher.ComputeHash(product);

        Assert.Equal(
            "bcb5419556eb16ff52d573c9fdfde26c0e2dd7d30715f42f9929c4fb237f8302",
            hash);
    }

    [Fact]
    public void ComputeHash_ChangesWhenPublishedBusinessFieldChanges()
    {
        var product = CreateProduct();

        var initial = ProductContentHasher.ComputeHash(product);
        var modified = ProductContentHasher.ComputeHash(
            product with { ShortDescription = "Description modifiée" });

        Assert.NotEqual(initial, modified);
    }

    [Fact]
    public void ComputeHash_IgnoresSourceAndSynchronizationDates()
    {
        var product = CreateProduct();

        var initial = ProductContentHasher.ComputeHash(product);
        var withAnotherSourceDate = ProductContentHasher.ComputeHash(
            product with { SourceUpdatedAtUtc = DateTimeOffset.Parse("2030-01-01T00:00:00Z") });

        Assert.Equal(initial, withAnotherSourceDate);
    }

    [Fact]
    public void CreatePayload_CopiesProductAndAddsItsHash()
    {
        var product = CreateProduct();

        var payload = ProductContentHasher.CreatePayload(product);

        Assert.Equal(product.SourceId, payload.SourceId);
        Assert.Equal(product.Name, payload.Name);
        Assert.Equal(ProductContentHasher.ComputeHash(product), payload.ContentHash);
    }

    private static ProductSyncItem CreateProduct() => new()
    {
        SourceId = "MOCK-0001",
        Reference = "REF-0001",
        Name = "Produit été",
        ShortDescription = "Description",
        FamilyCode = "FAM-A",
        FamilyLabel = "Famille A",
        Brand = "Marque A",
        SourceUpdatedAtUtc = DateTimeOffset.Parse("2026-08-20T08:00:00Z"),
    };
}
