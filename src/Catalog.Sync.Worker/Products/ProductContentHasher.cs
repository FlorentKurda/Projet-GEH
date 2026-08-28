using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Catalog.Contracts;

namespace Catalog.Sync.Worker.Products;

public static class ProductContentHasher
{
    public static string ComputeHash(ProductSyncItem product)
    {
        ArgumentNullException.ThrowIfNull(product);

        string?[] values =
        [
            product.SourceId,
            product.Reference,
            product.Name,
            product.ShortDescription,
            product.FamilyCode,
            product.FamilyLabel,
            product.Brand,
        ];

        var canonical = new StringBuilder();
        foreach (var value in values)
        {
            if (value is null)
            {
                canonical.Append("-1:\n");
                continue;
            }

            canonical
                .Append(Encoding.UTF8.GetByteCount(value).ToString(CultureInfo.InvariantCulture))
                .Append(':')
                .Append(value)
                .Append('\n');
        }

        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(canonical.ToString()));
        return Convert.ToHexStringLower(hash);
    }

    public static ProductSyncPayloadItem CreatePayload(ProductSyncItem product) => new()
    {
        SourceId = product.SourceId,
        Reference = product.Reference,
        Name = product.Name,
        ShortDescription = product.ShortDescription,
        FamilyCode = product.FamilyCode,
        FamilyLabel = product.FamilyLabel,
        Brand = product.Brand,
        SourceUpdatedAtUtc = product.SourceUpdatedAtUtc,
        ContentHash = ComputeHash(product),
    };
}
