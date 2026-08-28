namespace Catalog.Sync.Worker.Tests;

public sealed class ProgramTests
{
    [Fact]
    public async Task RunAsync_RejectsDryRunWithoutRunOnce()
    {
        var exitCode = await Catalog.Sync.Worker.Program.RunAsync(
            ["--dry-run"],
            CancellationToken.None);

        Assert.Equal(1, exitCode);
    }
}
