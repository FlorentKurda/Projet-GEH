using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Configuration;
using Catalog.Sync.Worker.Hosting;
using Catalog.Sync.Worker.Products;
using Catalog.Sync.Worker.Synchronization;
using Catalog.Sync.Worker.WordPress;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker.DependencyInjection;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCatalogSynchronization(
        this IServiceCollection services,
        bool continuousMode)
    {
        ArgumentNullException.ThrowIfNull(services);

        services
            .AddOptions<SyncOptions>()
            .BindConfiguration(SyncOptions.SectionName)
            .Validate(
                options => options.IntervalMinutes is >= 1 and <= 1_440,
                "Sync:IntervalMinutes doit être compris entre 1 et 1440.")
            .ValidateOnStart();

        services
            .AddOptions<ProductSourceOptions>()
            .BindConfiguration(ProductSourceOptions.SectionName)
            .Validate(
                options => !string.IsNullOrWhiteSpace(options.JsonFilePath),
                "ProductSource:JsonFilePath est obligatoire.")
            .ValidateOnStart();

        services.AddSingleton<IValidateOptions<WordPressOptions>, WordPressOptionsValidator>();
        services
            .AddOptions<WordPressOptions>()
            .BindConfiguration(WordPressOptions.SectionName)
            .ValidateOnStart();

        services.AddHttpClient(
            WordPressCatalogClient.HttpClientName,
            (serviceProvider, httpClient) =>
            {
                var options = serviceProvider.GetRequiredService<IOptions<WordPressOptions>>().Value;
                httpClient.BaseAddress = new Uri(
                    options.BaseUrl.TrimEnd('/') + "/",
                    UriKind.Absolute);
                httpClient.Timeout = TimeSpan.FromSeconds(options.RequestTimeoutSeconds);
            });

        services.AddSingleton<IProductSyncItemValidator, ProductSyncItemValidator>();
        services.AddSingleton<IProductSource, JsonProductSource>();
        services.AddSingleton<IWordPressCatalogClient, WordPressCatalogClient>();
        services.AddSingleton<ICatalogSynchronizationService, CatalogSynchronizationService>();
        services.AddSingleton<IRunOnceApplication, RunOnceApplication>();
        services.AddSingleton(TimeProvider.System);

        if (continuousMode)
        {
            services.AddHostedService<CatalogSyncWorker>();
        }

        return services;
    }
}
