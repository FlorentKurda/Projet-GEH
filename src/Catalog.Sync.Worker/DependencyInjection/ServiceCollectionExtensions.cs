using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Configuration;
using Catalog.Sync.Worker.Hosting;
using Catalog.Sync.Worker.Logging;
using Catalog.Sync.Worker.Products;
using Catalog.Sync.Worker.Synchronization;
using Catalog.Sync.Worker.WordPress;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker.DependencyInjection;

public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddCatalogSynchronization(
        this IServiceCollection services,
        bool continuousMode)
    {
        ArgumentNullException.ThrowIfNull(services);

        services.AddSingleton<IValidateOptions<SyncOptions>, SyncOptionsValidator>();
        services
            .AddOptions<SyncOptions>()
            .BindConfiguration(SyncOptions.SectionName)
            .ValidateOnStart();

        services.AddSingleton<IValidateOptions<FileLoggingOptions>, FileLoggingOptionsValidator>();
        services
            .AddOptions<FileLoggingOptions>()
            .BindConfiguration(FileLoggingOptions.SectionName)
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
        services.AddSingleton<IRetryDelay, RetryDelay>();
        services.AddSingleton<ICatalogSynchronizationService, CatalogSynchronizationService>();
        services.AddSingleton<IRunOnceApplication, RunOnceApplication>();
        services.AddSingleton(TimeProvider.System);
        services.AddSingleton<ISynchronizationScheduler, SynchronizationScheduler>();
        services.AddSingleton<ILoggerProvider, DailyFileLoggerProvider>();

        if (continuousMode)
        {
            services.AddHostedService<CatalogSyncWorker>();
        }

        return services;
    }
}
