using System.Text.Json;
using Catalog.Contracts;

namespace Catalog.Sync.Worker.Hosting;

public static class SyncResultMarker
{
    public const string Prefix = "CATALOG_SYNC_RESULT_V1";

    public static string Format(SyncResult result)
    {
        ArgumentNullException.ThrowIfNull(result);

        var payload = new
        {
            runId = result.RunId,
            status = result.Status,
            dryRun = result.DryRun,
            received = result.ReceivedCount,
            inserted = result.InsertedCount,
            updated = result.UpdatedCount,
            unchanged = result.UnchangedCount,
            reactivated = result.ReactivatedCount,
            deactivated = result.DeactivatedCount,
            candidates = result.CandidateDeactivationCount,
            deactivationPercentage = result.DeactivationPercentage,
            guardrail = result.GuardrailStatus,
        };

        return $"{Prefix} {JsonSerializer.Serialize(payload)}";
    }
}
