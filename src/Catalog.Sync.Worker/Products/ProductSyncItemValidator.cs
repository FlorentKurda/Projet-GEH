using Catalog.Contracts;
using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Errors;

namespace Catalog.Sync.Worker.Products;

public sealed class ProductSyncItemValidator : IProductSyncItemValidator
{
    public const int SourceIdMaxLength = 100;
    public const int ReferenceMaxLength = 100;
    public const int NameMaxLength = 255;
    public const int ShortDescriptionMaxLength = 2_000;
    public const int FamilyCodeMaxLength = 100;
    public const int FamilyLabelMaxLength = 255;
    public const int BrandMaxLength = 255;

    public ProductSyncItem ValidateAndNormalize(ProductSyncItem product)
    {
        ArgumentNullException.ThrowIfNull(product);

        var normalized = product with
        {
            SourceId = NormalizeRequired(product.SourceId, nameof(product.SourceId)),
            Reference = NormalizeRequired(product.Reference, nameof(product.Reference)),
            Name = NormalizeRequired(product.Name, nameof(product.Name)),
            ShortDescription = NormalizeOptional(product.ShortDescription),
            FamilyCode = NormalizeOptional(product.FamilyCode),
            FamilyLabel = NormalizeOptional(product.FamilyLabel),
            Brand = NormalizeOptional(product.Brand),
        };

        EnsureMaximumLength(normalized.SourceId, SourceIdMaxLength, nameof(product.SourceId));
        EnsureMaximumLength(normalized.Reference, ReferenceMaxLength, nameof(product.Reference));
        EnsureMaximumLength(normalized.Name, NameMaxLength, nameof(product.Name));
        EnsureMaximumLength(
            normalized.ShortDescription,
            ShortDescriptionMaxLength,
            nameof(product.ShortDescription));
        EnsureMaximumLength(normalized.FamilyCode, FamilyCodeMaxLength, nameof(product.FamilyCode));
        EnsureMaximumLength(normalized.FamilyLabel, FamilyLabelMaxLength, nameof(product.FamilyLabel));
        EnsureMaximumLength(normalized.Brand, BrandMaxLength, nameof(product.Brand));

        return normalized;
    }

    private static string NormalizeRequired(string? value, string propertyName)
    {
        var normalized = value?.Trim();
        if (string.IsNullOrEmpty(normalized))
        {
            throw new ProductValidationException($"Le champ {propertyName} est obligatoire.");
        }

        return normalized;
    }

    private static string? NormalizeOptional(string? value)
    {
        var normalized = value?.Trim();
        return string.IsNullOrEmpty(normalized) ? null : normalized;
    }

    private static void EnsureMaximumLength(string? value, int maximumLength, string propertyName)
    {
        if (value is not null && value.Length > maximumLength)
        {
            throw new ProductValidationException(
                $"Le champ {propertyName} ne doit pas dépasser {maximumLength} caractères.");
        }
    }
}
