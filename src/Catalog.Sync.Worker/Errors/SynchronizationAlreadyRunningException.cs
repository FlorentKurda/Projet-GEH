namespace Catalog.Sync.Worker.Errors;

public sealed class SynchronizationAlreadyRunningException : InvalidOperationException
{
    public SynchronizationAlreadyRunningException()
        : base("Une synchronisation locale est déjà en cours.")
    {
    }
}
