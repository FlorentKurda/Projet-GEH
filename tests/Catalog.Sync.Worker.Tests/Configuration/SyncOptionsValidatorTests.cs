using Catalog.Sync.Worker.Configuration;

namespace Catalog.Sync.Worker.Tests.Configuration;

public sealed class SyncOptionsValidatorTests
{
    private readonly SyncOptionsValidator _validator = new();

    [Fact]
    public void Validate_AcceptsValidConfiguration()
    {
        var result = _validator.Validate(null, new SyncOptions
        {
            IntervalMinutes = 15,
            RunOnStartup = true,
            BatchSize = 200,
        });

        Assert.True(result.Succeeded);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    [InlineData(1_441)]
    public void Validate_RejectsInvalidInterval(int intervalMinutes)
    {
        var result = _validator.Validate(null, new SyncOptions
        {
            IntervalMinutes = intervalMinutes,
            BatchSize = 200,
        });

        Assert.True(result.Failed);
        Assert.Contains(result.Failures, failure => failure.Contains("IntervalMinutes"));
    }
}
