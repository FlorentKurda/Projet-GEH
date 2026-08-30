using System.Text.Json;
using System.Text.Json.Serialization;
using Catalog.Contracts;
using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Configuration;
using Catalog.Sync.Worker.Errors;
using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker.Products;

public sealed class JsonProductSource : IProductSource
{
    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    };

    private readonly string _configuredPath;
    private readonly IProductSyncItemValidator _validator;

    public JsonProductSource(
        IOptions<ProductSourceOptions> options,
        IProductSyncItemValidator validator)
    {
        ArgumentNullException.ThrowIfNull(options);
        _validator = validator ?? throw new ArgumentNullException(nameof(validator));
        _configuredPath = options.Value.JsonFilePath;
    }

    public async Task<IReadOnlyCollection<ProductSyncItem>> GetProductsAsync(
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();

        var path = ResolvePath(_configuredPath);
        if (!File.Exists(path))
        {
            throw new ProductSourceException($"Le fichier JSON de produits est introuvable : '{path}'.");
        }

        List<ProductSyncItem?>? deserializedProducts;
        try
        {
            await using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                bufferSize: 16_384,
                FileOptions.Asynchronous | FileOptions.SequentialScan);

            deserializedProducts = await JsonSerializer.DeserializeAsync<List<ProductSyncItem?>>(
                stream,
                SerializerOptions,
                cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (JsonException exception)
        {
            throw new ProductSourceException(
                "Le fichier JSON de produits est invalide ou contient une valeur d'un type incorrect.",
                exception);
        }
        catch (IOException exception)
        {
            throw new ProductSourceException("Le fichier JSON de produits ne peut pas être lu.", exception);
        }
        catch (UnauthorizedAccessException exception)
        {
            throw new ProductSourceException("L'accès au fichier JSON de produits est refusé.", exception);
        }

        if (deserializedProducts is null)
        {
            throw new ProductSourceException("Le fichier JSON doit contenir un tableau de produits.");
        }

        var products = new List<ProductSyncItem>(deserializedProducts.Count);
        var sourceIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        for (var index = 0; index < deserializedProducts.Count; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();

            var product = deserializedProducts[index];
            if (product is null)
            {
                throw new ProductValidationException(
                    $"Le produit à l'index {index} ne peut pas être null.");
            }

            ProductSyncItem normalized;
            try
            {
                normalized = _validator.ValidateAndNormalize(product);
            }
            catch (ProductValidationException exception)
            {
                throw new ProductValidationException(
                    $"Produit invalide à l'index {index} : {exception.Message}");
            }

            if (!sourceIds.Add(normalized.SourceId))
            {
                throw new ProductValidationException(
                    $"Le SourceId '{normalized.SourceId}' est présent plusieurs fois dans le fichier JSON.");
            }

            products.Add(normalized);
        }

        return products;
    }

    private static string ResolvePath(string configuredPath)
    {
        if (string.IsNullOrWhiteSpace(configuredPath))
        {
            throw new ProductSourceException("ProductSource:JsonFilePath est obligatoire.");
        }

        try
        {
            var trimmedPath = configuredPath.Trim();
            return Path.IsPathRooted(trimmedPath)
                ? Path.GetFullPath(trimmedPath)
                : Path.GetFullPath(trimmedPath, AppContext.BaseDirectory);
        }
        catch (Exception exception) when (
            exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new ProductSourceException("ProductSource:JsonFilePath est invalide.", exception);
        }
    }
}
