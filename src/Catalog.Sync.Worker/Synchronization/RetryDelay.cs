using Catalog.Sync.Worker.Abstractions;

namespace Catalog.Sync.Worker.Synchronization;

public sealed class RetryDelay(TimeProvider timeProvider) : IRetryDelay
{
    private readonly TimeProvider _timeProvider = timeProvider ??
        throw new ArgumentNullException(nameof(timeProvider));

    public Task DelayAsync(TimeSpan delay, CancellationToken cancellationToken) =>
        Task.Delay(delay, _timeProvider, cancellationToken);
}
