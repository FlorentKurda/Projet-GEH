namespace Catalog.Sync.Worker.Abstractions;

public interface IRunOnceApplication
{
    Task<int> ExecuteAsync(bool dryRun, CancellationToken cancellationToken);
}
