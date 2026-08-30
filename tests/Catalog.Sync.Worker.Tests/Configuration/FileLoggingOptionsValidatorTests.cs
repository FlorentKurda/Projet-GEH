using Catalog.Sync.Worker.Configuration;

namespace Catalog.Sync.Worker.Tests.Configuration;

public sealed class FileLoggingOptionsValidatorTests
{
    private readonly FileLoggingOptionsValidator _validator = new();

    [Fact]
    public void Validate_AcceptsValidConfiguration()
    {
        var result = _validator.Validate(null, new FileLoggingOptions
        {
            Enabled = true,
            DirectoryPath = "logs",
            RetentionDays = 30,
        });

        Assert.True(result.Succeeded);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    [InlineData(3_651)]
    public void Validate_RejectsInvalidRetention(int retentionDays)
    {
        var result = _validator.Validate(null, new FileLoggingOptions
        {
            Enabled = true,
            DirectoryPath = "logs",
            RetentionDays = retentionDays,
        });

        Assert.True(result.Failed);
        Assert.Contains(result.Failures, failure => failure.Contains("RetentionDays"));
    }

    [Fact]
    public void Validate_RejectsEmptyDirectoryWhenEnabled()
    {
        var result = _validator.Validate(null, new FileLoggingOptions
        {
            Enabled = true,
            DirectoryPath = " ",
            RetentionDays = 30,
        });

        Assert.True(result.Failed);
        Assert.Contains(result.Failures, failure => failure.Contains("DirectoryPath"));
    }
}
