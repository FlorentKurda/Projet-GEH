using System.Diagnostics;
using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Configuration;
using Catalog.Sync.Worker.Errors;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker.Hosting;

public sealed class SynchronizationScheduler : ISynchronizationScheduler
{
    private readonly ICatalogSynchronizationService _synchronizationService;
    private readonly TimeProvider _timeProvider;
    private readonly TimeSpan _interval;
    private readonly bool _runOnStartup;
    private readonly ILogger<SynchronizationScheduler> _logger;

    public SynchronizationScheduler(
        ICatalogSynchronizationService synchronizationService,
        TimeProvider timeProvider,
        IOptions<SyncOptions> options,
        ILogger<SynchronizationScheduler> logger)
    {
        _synchronizationService = synchronizationService ??
            throw new ArgumentNullException(nameof(synchronizationService));
        _timeProvider = timeProvider ?? throw new ArgumentNullException(nameof(timeProvider));
        ArgumentNullException.ThrowIfNull(options);
        _interval = TimeSpan.FromMinutes(options.Value.IntervalMinutes);
        _runOnStartup = options.Value.RunOnStartup;
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    public async Task RunAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(_interval, _timeProvider);
        Task? activeSynchronization = null;

        try
        {
            if (_runOnStartup)
            {
                activeSynchronization = ExecuteCycleAsync(cancellationToken);
            }
            else
            {
                _logger.LogInformation(
                    "Première synchronisation planifiée dans {IntervalMinutes} minute(s).",
                    _interval.TotalMinutes);
            }

            while (await timer.WaitForNextTickAsync(cancellationToken))
            {
                if (activeSynchronization is { IsCompleted: false })
                {
                    _logger.LogWarning(
                        "Synchronisation précédente encore en cours, cycle ignoré.");
                    continue;
                }

                if (cancellationToken.IsCancellationRequested)
                {
                    break;
                }

                activeSynchronization = ExecuteCycleAsync(cancellationToken);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Arrêt normal demandé par le Generic Host ou le Service Control Manager.
        }
        finally
        {
            if (activeSynchronization is not null)
            {
                try
                {
                    await activeSynchronization;
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    // La synchronisation en cours a observé l'arrêt du service.
                }
            }
        }
    }

    private async Task ExecuteCycleAsync(CancellationToken cancellationToken)
    {
        var stopwatch = Stopwatch.StartNew();
        _logger.LogInformation("Début d'un cycle de synchronisation.");

        try
        {
            var result = await _synchronizationService.SynchronizeAsync(
                dryRun: false,
                cancellationToken);
            stopwatch.Stop();

            _logger.LogInformation(
                "Cycle {RunId} terminé en {DurationMilliseconds} ms : " +
                "{InsertedCount} insérés, {UpdatedCount} modifiés, " +
                "{UnchangedCount} inchangés, {ReactivatedCount} réactivés, " +
                "{DeactivatedCount} désactivés.",
                result.RunId,
                stopwatch.ElapsedMilliseconds,
                result.InsertedCount,
                result.UpdatedCount,
                result.UnchangedCount,
                result.ReactivatedCount,
                result.DeactivatedCount);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            stopwatch.Stop();
            _logger.LogInformation(
                "Cycle de synchronisation annulé après {DurationMilliseconds} ms.",
                stopwatch.ElapsedMilliseconds);
            throw;
        }
        catch (SynchronizationAlreadyRunningException exception)
        {
            stopwatch.Stop();
            _logger.LogWarning(
                exception,
                "Synchronisation précédente encore en cours, cycle ignoré.");
        }
        catch (WordPressCatalogException exception)
        {
            stopwatch.Stop();
            _logger.LogError(
                exception,
                "Échec WordPress ou réseau après {DurationMilliseconds} ms. " +
                "Le service réessaiera au prochain cycle.",
                stopwatch.ElapsedMilliseconds);
        }
        catch (ProductSourceException exception)
        {
            stopwatch.Stop();
            _logger.LogError(
                exception,
                "Échec de lecture de la source produit après {DurationMilliseconds} ms. " +
                "Le service reste actif.",
                stopwatch.ElapsedMilliseconds);
        }
        catch (ProductValidationException exception)
        {
            stopwatch.Stop();
            _logger.LogError(
                exception,
                "Synchronisation rejetée par la validation métier après {DurationMilliseconds} ms. " +
                "Le service reste actif.",
                stopwatch.ElapsedMilliseconds);
        }
        catch (Exception exception)
        {
            stopwatch.Stop();
            _logger.LogError(
                exception,
                "La synchronisation a échoué après {DurationMilliseconds} ms. " +
                "Le service réessaiera au prochain cycle.",
                stopwatch.ElapsedMilliseconds);
        }
    }
}
