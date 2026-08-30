using Catalog.Contracts;
using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Configuration;
using Catalog.Sync.Worker.Errors;
using Catalog.Sync.Worker.Hosting;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Microsoft.Extensions.Time.Testing;

namespace Catalog.Sync.Worker.Tests.Hosting;

public sealed class SynchronizationSchedulerTests
{
    [Fact]
    public async Task RunAsync_RunOnStartupStartsImmediately()
    {
        var service = new ControllableSynchronizationService();
        var time = CreateTimeProvider();
        using var cancellation = new CancellationTokenSource();
        var schedulerTask = CreateScheduler(service, time, runOnStartup: true)
            .RunAsync(cancellation.Token);

        await service.WaitForCallCountAsync(1);

        cancellation.Cancel();
        await schedulerTask;
        Assert.Equal(1, service.CallCount);
    }

    [Fact]
    public async Task RunAsync_RunOnStartupFalseWaitsForFirstTick()
    {
        var service = new ControllableSynchronizationService();
        var time = CreateTimeProvider();
        using var cancellation = new CancellationTokenSource();
        var schedulerTask = CreateScheduler(service, time, runOnStartup: false)
            .RunAsync(cancellation.Token);

        Assert.Equal(0, service.CallCount);
        time.Advance(TimeSpan.FromMinutes(1));
        await service.WaitForCallCountAsync(1);

        cancellation.Cancel();
        await schedulerTask;
    }

    [Fact]
    public async Task RunAsync_SynchronizationFailureDoesNotStopScheduler()
    {
        var service = new ControllableSynchronizationService(
            (_, _) => Task.FromException<SyncResult>(new ProductSourceException("Source indisponible.")));
        var time = CreateTimeProvider();
        using var cancellation = new CancellationTokenSource();
        var schedulerTask = CreateScheduler(service, time, runOnStartup: true)
            .RunAsync(cancellation.Token);

        await service.WaitForCallCountAsync(1);
        time.Advance(TimeSpan.FromMinutes(1));
        await service.WaitForCallCountAsync(2);

        cancellation.Cancel();
        await schedulerTask;
    }

    [Fact]
    public async Task RunAsync_AlreadyRunningFailureDoesNotStopScheduler()
    {
        var service = new ControllableSynchronizationService(
            (_, _) => Task.FromException<SyncResult>(
                new SynchronizationAlreadyRunningException()));
        var time = CreateTimeProvider();
        using var cancellation = new CancellationTokenSource();
        var schedulerTask = CreateScheduler(service, time, runOnStartup: true)
            .RunAsync(cancellation.Token);

        await service.WaitForCallCountAsync(1);
        time.Advance(TimeSpan.FromMinutes(1));
        await service.WaitForCallCountAsync(2);

        cancellation.Cancel();
        await schedulerTask;
    }

    [Fact]
    public async Task RunAsync_DoesNotOverlapLocalSynchronizations()
    {
        var firstCall = new TaskCompletionSource<SyncResult>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var service = new ControllableSynchronizationService(
            (call, _) => call == 1 ? firstCall.Task : Task.FromResult(CreateResult()));
        var time = CreateTimeProvider();
        using var cancellation = new CancellationTokenSource();
        var schedulerTask = CreateScheduler(service, time, runOnStartup: true)
            .RunAsync(cancellation.Token);

        await service.WaitForCallCountAsync(1);
        time.Advance(TimeSpan.FromMinutes(1));
        time.Advance(TimeSpan.FromMinutes(1));
        Assert.Equal(1, service.CallCount);
        Assert.Equal(1, service.MaximumConcurrentCalls);

        firstCall.SetResult(CreateResult());
        await service.WaitForIdleAsync();

        cancellation.Cancel();
        await schedulerTask;
        Assert.Equal(1, service.MaximumConcurrentCalls);
    }

    [Fact]
    public async Task RunAsync_CancellationStopsCleanlyAndReachesSynchronization()
    {
        var service = new ControllableSynchronizationService(
            async (_, cancellationToken) =>
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
                return CreateResult();
            });
        var time = CreateTimeProvider();
        using var cancellation = new CancellationTokenSource();
        var schedulerTask = CreateScheduler(service, time, runOnStartup: true)
            .RunAsync(cancellation.Token);

        await service.WaitForCallCountAsync(1);
        cancellation.Cancel();

        await schedulerTask;
        Assert.True(service.LastCancellationToken.IsCancellationRequested);
    }

    private static SynchronizationScheduler CreateScheduler(
        ICatalogSynchronizationService service,
        TimeProvider timeProvider,
        bool runOnStartup) =>
        new(
            service,
            timeProvider,
            Options.Create(new SyncOptions
            {
                IntervalMinutes = 1,
                RunOnStartup = runOnStartup,
                BatchSize = 200,
            }),
            NullLogger<SynchronizationScheduler>.Instance);

    private static FakeTimeProvider CreateTimeProvider() =>
        new(new DateTimeOffset(2026, 8, 30, 12, 0, 0, TimeSpan.Zero));

    private static SyncResult CreateResult() => new()
    {
        RunId = Guid.NewGuid(),
        Status = "completed",
        ReceivedCount = 1,
        InsertedCount = 1,
        UpdatedCount = 0,
        UnchangedCount = 0,
        ReactivatedCount = 0,
        DeactivatedCount = 0,
        CandidateDeactivationCount = 0,
        ActiveBeforeCount = 0,
        DeactivationPercentage = 0,
        GuardrailStatus = "passed",
        DryRun = false,
    };

    private sealed class ControllableSynchronizationService : ICatalogSynchronizationService
    {
        private readonly Func<int, CancellationToken, Task<SyncResult>> _handler;
        private readonly object _gate = new();
        private TaskCompletionSource _callSignal = NewSignal();
        private TaskCompletionSource _idleSignal = CompletedSignal();
        private int _activeCalls;

        public ControllableSynchronizationService(
            Func<int, CancellationToken, Task<SyncResult>>? handler = null)
        {
            _handler = handler ?? ((_, _) => Task.FromResult(CreateResult()));
        }

        public int CallCount { get; private set; }

        public int MaximumConcurrentCalls { get; private set; }

        public CancellationToken LastCancellationToken { get; private set; }

        public async Task<SyncResult> SynchronizeAsync(
            bool dryRun,
            CancellationToken cancellationToken)
        {
            int call;
            lock (_gate)
            {
                CallCount++;
                call = CallCount;
                if (_activeCalls == 0)
                {
                    _idleSignal = NewSignal();
                }

                _activeCalls++;
                MaximumConcurrentCalls = Math.Max(MaximumConcurrentCalls, _activeCalls);
                LastCancellationToken = cancellationToken;
                _callSignal.TrySetResult();
            }

            try
            {
                return await _handler(call, cancellationToken);
            }
            finally
            {
                lock (_gate)
                {
                    _activeCalls--;
                    if (_activeCalls == 0)
                    {
                        _idleSignal.TrySetResult();
                    }
                }
            }
        }

        public Task WaitForIdleAsync()
        {
            lock (_gate)
            {
                return _idleSignal.Task.WaitAsync(TimeSpan.FromSeconds(5));
            }
        }

        public async Task WaitForCallCountAsync(int expected)
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            while (true)
            {
                Task signal;
                lock (_gate)
                {
                    if (CallCount >= expected)
                    {
                        return;
                    }

                    signal = _callSignal.Task;
                }

                await signal.WaitAsync(timeout.Token);
                lock (_gate)
                {
                    if (_callSignal.Task.IsCompleted)
                    {
                        _callSignal = NewSignal();
                    }
                }
            }
        }

        private static TaskCompletionSource NewSignal() =>
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        private static TaskCompletionSource CompletedSignal()
        {
            var signal = NewSignal();
            signal.SetResult();
            return signal;
        }
    }
}
