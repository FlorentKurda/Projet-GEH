using System.Text.Json;
using Catalog.Contracts;
using Catalog.Sync.Worker.Hosting;

namespace Catalog.Sync.Worker.Tests.Hosting;

public sealed class SyncResultMarkerTests
{
    [Fact]
    public void Format_ProducesAnAsciiStructuredMarkerWithInvariantValues()
    {
        var result = new SyncResult
        {
            RunId = Guid.Parse("71c7ea7a-55c4-4fc0-a721-6ac4cd8e3280"),
            Status = "complété",
            ReceivedCount = 60,
            InsertedCount = 2,
            UpdatedCount = 3,
            UnchangedCount = 55,
            ReactivatedCount = 0,
            DeactivatedCount = 2,
            CandidateDeactivationCount = 2,
            ActiveBeforeCount = 60,
            DeactivationPercentage = 3.33m,
            GuardrailStatus = "accepté",
            DryRun = true,
        };

        var marker = SyncResultMarker.Format(result);

        Assert.StartsWith($"{SyncResultMarker.Prefix} ", marker, StringComparison.Ordinal);
        Assert.All(marker, character => Assert.InRange((int)character, 0, 127));

        var json = marker[(SyncResultMarker.Prefix.Length + 1)..];
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;

        Assert.Equal(result.RunId, root.GetProperty("runId").GetGuid());
        Assert.Equal(result.Status, root.GetProperty("status").GetString());
        Assert.True(root.GetProperty("dryRun").GetBoolean());
        Assert.Equal(60, root.GetProperty("received").GetInt32());
        Assert.Equal(55, root.GetProperty("unchanged").GetInt32());
        Assert.Equal(3.33m, root.GetProperty("deactivationPercentage").GetDecimal());
        Assert.Equal(result.GuardrailStatus, root.GetProperty("guardrail").GetString());
    }
}
