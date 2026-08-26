using Catalog.Contracts;
using Catalog.Sync.Worker.Errors;
using Catalog.Sync.Worker.Products;

namespace Catalog.Sync.Worker.Tests.Products;

public sealed class ProductSyncItemValidatorTests
{
    private readonly ProductSyncItemValidator _validator = new();

    [Fact]
    public void ValidateAndNormalize_AcceptsValidProductAndTrimsText()
    {
        var product = CreateValidProduct() with
        {
            SourceId = "  MOCK-0001  ",
            Reference = "  REF-0001  ",
            Name = "  Produit été  ",
            ShortDescription = "  Description  ",
            FamilyCode = "  FAM-A  ",
            FamilyLabel = "  Famille A  ",
            Brand = "  Marque A  ",
        };

        var result = _validator.ValidateAndNormalize(product);

        Assert.Equal("MOCK-0001", result.SourceId);
        Assert.Equal("REF-0001", result.Reference);
        Assert.Equal("Produit été", result.Name);
        Assert.Equal("Description", result.ShortDescription);
        Assert.Equal("FAM-A", result.FamilyCode);
        Assert.Equal("Famille A", result.FamilyLabel);
        Assert.Equal("Marque A", result.Brand);
    }

    [Fact]
    public void ValidateAndNormalize_ConvertsWhitespaceOnlyOptionalTextToNull()
    {
        var product = CreateValidProduct() with
        {
            ShortDescription = "   ",
            FamilyCode = "\t",
            FamilyLabel = null,
            Brand = "\r\n",
        };

        var result = _validator.ValidateAndNormalize(product);

        Assert.Null(result.ShortDescription);
        Assert.Null(result.FamilyCode);
        Assert.Null(result.FamilyLabel);
        Assert.Null(result.Brand);
    }

    [Theory]
    [InlineData("SourceId")]
    [InlineData("Reference")]
    [InlineData("Name")]
    public void ValidateAndNormalize_RejectsEmptyRequiredField(string propertyName)
    {
        var product = propertyName switch
        {
            "SourceId" => CreateValidProduct() with { SourceId = "   " },
            "Reference" => CreateValidProduct() with { Reference = "" },
            "Name" => CreateValidProduct() with { Name = "\t" },
            _ => throw new ArgumentOutOfRangeException(nameof(propertyName)),
        };

        var exception = Assert.Throws<ProductValidationException>(
            () => _validator.ValidateAndNormalize(product));

        Assert.Contains(propertyName, exception.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("SourceId", ProductSyncItemValidator.SourceIdMaxLength)]
    [InlineData("Reference", ProductSyncItemValidator.ReferenceMaxLength)]
    [InlineData("Name", ProductSyncItemValidator.NameMaxLength)]
    [InlineData("ShortDescription", ProductSyncItemValidator.ShortDescriptionMaxLength)]
    [InlineData("FamilyCode", ProductSyncItemValidator.FamilyCodeMaxLength)]
    [InlineData("FamilyLabel", ProductSyncItemValidator.FamilyLabelMaxLength)]
    [InlineData("Brand", ProductSyncItemValidator.BrandMaxLength)]
    public void ValidateAndNormalize_RejectsTextOverMaximumLength(
        string propertyName,
        int maximumLength)
    {
        var oversizedValue = new string('x', maximumLength + 1);
        var product = propertyName switch
        {
            "SourceId" => CreateValidProduct() with { SourceId = oversizedValue },
            "Reference" => CreateValidProduct() with { Reference = oversizedValue },
            "Name" => CreateValidProduct() with { Name = oversizedValue },
            "ShortDescription" => CreateValidProduct() with { ShortDescription = oversizedValue },
            "FamilyCode" => CreateValidProduct() with { FamilyCode = oversizedValue },
            "FamilyLabel" => CreateValidProduct() with { FamilyLabel = oversizedValue },
            "Brand" => CreateValidProduct() with { Brand = oversizedValue },
            _ => throw new ArgumentOutOfRangeException(nameof(propertyName)),
        };

        var exception = Assert.Throws<ProductValidationException>(
            () => _validator.ValidateAndNormalize(product));

        Assert.Contains(propertyName, exception.Message, StringComparison.Ordinal);
    }

    private static ProductSyncItem CreateValidProduct()
    {
        return new ProductSyncItem
        {
            SourceId = "MOCK-0001",
            Reference = "REF-0001",
            Name = "Produit exemple",
            ShortDescription = "Description courte",
            FamilyCode = "FAM-A",
            FamilyLabel = "Famille A",
            Brand = "Marque A",
            SourceUpdatedAtUtc = DateTimeOffset.Parse("2026-08-20T08:00:00Z"),
        };
    }
}
