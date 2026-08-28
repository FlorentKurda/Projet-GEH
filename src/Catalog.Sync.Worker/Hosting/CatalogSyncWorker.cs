using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker.Hosting;

public sealed class CatalogSyncWorker : BackgroundService
{
    private readonly ICatalogSynchronizationService _synchronizationService;
    private readonly TimeProvider _timeProvider;
    private readonly TimeSpan _interval;
    private readonly ILogger<CatalogSyncWorker> _logger;

    public CatalogSyncWorker(
        ICatalogSynchronizationService synchronizationService,
        TimeProvider timeProvider,
        IOptions<SyncOptions> options,
        ILogger<CatalogSyncWorker> logger)
    {
        _synchronizationService = synchronizationService ??
            throw new ArgumentNullException(nameof(synchronizationService));
        _timeProvider = timeProvider ?? throw new ArgumentNullException(nameof(timeProvider));
        ArgumentNullException.ThrowIfNull(options);
        _interval = TimeSpan.FromMinutes(options.Value.IntervalMinutes);
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await _synchronizationService.SynchronizeAsync(
                    dryRun: false,
                    stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception)
            {
                _logger.LogError(
                    exception,
                    "La synchronisation a échoué. Une nouvelle tentative aura lieu au prochain intervalle.");
            }

            try
            {
                await Task.Delay(_interval, _timeProvider, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
        }

        _logger.LogInformation("Worker de synchronisation arrêté proprement.");
    }
}
