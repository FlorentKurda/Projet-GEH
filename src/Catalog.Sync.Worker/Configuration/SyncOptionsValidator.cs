using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker.Configuration;

public sealed class SyncOptionsValidator : IValidateOptions<SyncOptions>
{
    public ValidateOptionsResult Validate(string? name, SyncOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        var failures = new List<string>();
        if (options.IntervalMinutes is < 1 or > 1_440)
        {
            failures.Add("Sync:IntervalMinutes doit être compris entre 1 et 1440.");
        }

        if (options.BatchSize is < 1 or > 500)
        {
            failures.Add("Sync:BatchSize doit être compris entre 1 et 500.");
        }

        return failures.Count == 0
            ? ValidateOptionsResult.Success
            : ValidateOptionsResult.Fail(failures);
    }
}
