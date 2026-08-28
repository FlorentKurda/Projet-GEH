using Catalog.Sync.Worker.Abstractions;
using Microsoft.Extensions.Logging;

namespace Catalog.Sync.Worker.Hosting;

public sealed class RunOnceApplication : IRunOnceApplication
{
    private readonly ICatalogSynchronizationService _synchronizationService;
    private readonly ILogger<RunOnceApplication> _logger;

    public RunOnceApplication(
        ICatalogSynchronizationService synchronizationService,
        ILogger<RunOnceApplication> logger)
    {
        _synchronizationService = synchronizationService ??
            throw new ArgumentNullException(nameof(synchronizationService));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    public async Task<int> ExecuteAsync(bool dryRun, CancellationToken cancellationToken)
    {
        try
        {
            var result = await _synchronizationService.SynchronizeAsync(dryRun, cancellationToken);
            Console.Out.WriteLine(SyncResultMarker.Format(result));
            _logger.LogInformation("Exécution ponctuelle terminée avec succès.");
            return 0;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            _logger.LogWarning("Exécution ponctuelle annulée.");
            return 1;
        }
        catch (Exception exception)
        {
            _logger.LogError(exception, "Échec de l'exécution ponctuelle.");
            return 1;
        }
    }
}
