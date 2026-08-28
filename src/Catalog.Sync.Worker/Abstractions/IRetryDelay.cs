namespace Catalog.Sync.Worker.Abstractions;

public interface IRetryDelay
{
    Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken);
}
