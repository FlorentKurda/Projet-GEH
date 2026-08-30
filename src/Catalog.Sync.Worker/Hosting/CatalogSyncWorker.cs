using Catalog.Sync.Worker.Abstractions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace Catalog.Sync.Worker.Hosting;

public sealed class CatalogSyncWorker : BackgroundService
{
    private readonly ISynchronizationScheduler _scheduler;
    private readonly ILogger<CatalogSyncWorker> _logger;

    public CatalogSyncWorker(
        ISynchronizationScheduler scheduler,
        ILogger<CatalogSyncWorker> logger)
    {
        _scheduler = scheduler ?? throw new ArgumentNullException(nameof(scheduler));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            await _scheduler.RunAsync(stoppingToken);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            // Arrêt normal du service.
        }

        _logger.LogInformation("Worker de synchronisation arrêté proprement.");
    }
}
