using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker.Configuration;

public sealed class FileLoggingOptionsValidator : IValidateOptions<FileLoggingOptions>
{
    public ValidateOptionsResult Validate(string? name, FileLoggingOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        var failures = new List<string>();
        if (options.Enabled && string.IsNullOrWhiteSpace(options.DirectoryPath))
        {
            failures.Add("FileLogging:DirectoryPath est obligatoire lorsque les logs fichiers sont activés.");
        }

        if (options.RetentionDays is < 1 or > 3_650)
        {
            failures.Add("FileLogging:RetentionDays doit être compris entre 1 et 3650.");
        }

        return failures.Count == 0
            ? ValidateOptionsResult.Success
            : ValidateOptionsResult.Fail(failures);
    }
}
