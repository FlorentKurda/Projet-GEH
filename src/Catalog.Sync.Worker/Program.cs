using Catalog.Sync.Worker.Abstractions;
using Catalog.Sync.Worker.Configuration;
using Catalog.Sync.Worker.DependencyInjection;
using System.Reflection;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Hosting.WindowsServices;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace Catalog.Sync.Worker;

public static class Program
{
    private const string RunOnceArgument = "--run-once";
    private const string DryRunArgument = "--dry-run";

    public static Task<int> Main(string[] args)
    {
        return RunAsync(args, CancellationToken.None);
    }

    public static async Task<int> RunAsync(
        string[] args,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(args);

        var runOnce = args.Any(
            argument => string.Equals(argument, RunOnceArgument, StringComparison.OrdinalIgnoreCase));
        var dryRun = args.Any(
            argument => string.Equals(argument, DryRunArgument, StringComparison.OrdinalIgnoreCase));

        if (dryRun && !runOnce)
        {
            Console.Error.WriteLine("L'option --dry-run doit être utilisée avec --run-once.");
            return 1;
        }

        var hostArguments = args
            .Where(argument =>
                !string.Equals(argument, RunOnceArgument, StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(argument, DryRunArgument, StringComparison.OrdinalIgnoreCase))
            .ToArray();

        try
        {
            var builder = Host.CreateApplicationBuilder(hostArguments);
            builder.Services.AddWindowsService(options =>
            {
                options.ServiceName = "GEHProductCatalogSync";
            });
            builder.Services.AddCatalogSynchronization(continuousMode: !runOnce);

            using var host = builder.Build();
            LogStartupConfiguration(host.Services, builder.Environment, runOnce, dryRun);

            if (runOnce)
            {
                await host.StartAsync(cancellationToken);
                var exitCode = await host.Services
                    .GetRequiredService<IRunOnceApplication>()
                    .ExecuteAsync(dryRun, cancellationToken);
                await host.StopAsync(CancellationToken.None);
                return exitCode;
            }

            await host.RunAsync(cancellationToken);
            return 0;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return runOnce ? 1 : 0;
        }
        catch (OptionsValidationException exception)
        {
            Console.Error.WriteLine($"Configuration invalide : {exception.Message}");
            return 1;
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine(
                $"Le Worker n'a pas pu démarrer ({exception.GetType().Name}).");
            return 1;
        }
    }

    private static void LogStartupConfiguration(
        IServiceProvider services,
        IHostEnvironment environment,
        bool runOnce,
        bool dryRun)
    {
        var syncOptions = services.GetRequiredService<IOptions<SyncOptions>>().Value;
        var wordPressOptions = services.GetRequiredService<IOptions<WordPressOptions>>().Value;
        var fileLoggingOptions = services.GetRequiredService<IOptions<FileLoggingOptions>>().Value;
        var logger = services.GetRequiredService<ILoggerFactory>().CreateLogger("Catalog.Sync.Worker");
        var workerVersion = GetWorkerVersion();
        var executionMode = runOnce
            ? dryRun ? "run-once dry-run" : "run-once"
            : WindowsServiceHelpers.IsWindowsService() ? "service Windows" : "console continue";

        logger.LogInformation(
            "Démarrage Worker. Catalog.Sync.Worker version {WorkerVersion}; " +
            "Environnement={Environment}; Mode={ExecutionMode}; " +
            "WordPressBaseUrl={WordPressBaseUrl}; ProductSource=JsonProductSource; " +
            "IntervalMinutes={IntervalMinutes}; RunOnStartup={RunOnStartup}; " +
            "FileLoggingEnabled={FileLoggingEnabled}; FileLoggingDirectory={FileLoggingDirectory}; " +
            "FileLoggingRetentionDays={FileLoggingRetentionDays}.",
            workerVersion,
            environment.EnvironmentName,
            executionMode,
            wordPressOptions.BaseUrl,
            syncOptions.IntervalMinutes,
            syncOptions.RunOnStartup,
            fileLoggingOptions.Enabled,
            fileLoggingOptions.DirectoryPath,
            fileLoggingOptions.RetentionDays);
    }

    private static string GetWorkerVersion()
    {
        var assembly = typeof(Program).Assembly;
        var informationalVersion = assembly
            .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?
            .InformationalVersion;

        if (!string.IsNullOrWhiteSpace(informationalVersion))
        {
            return informationalVersion.Split('+', 2)[0];
        }

        return assembly.GetName().Version?.ToString(3) ?? "inconnue";
    }
}
