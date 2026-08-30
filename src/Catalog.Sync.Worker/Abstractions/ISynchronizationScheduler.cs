namespace Catalog.Sync.Worker.Abstractions;

public interface ISynchronizationScheduler
{
    Task RunAsync(CancellationToken cancellationToken);
}
