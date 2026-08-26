namespace Catalog.Sync.Worker.Abstractions;

public interface IRunOnceApplication
{
    Task<int> ExecuteAsync(CancellationToken cancellationToken);
}
