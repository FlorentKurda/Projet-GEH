using Catalog.Sync.Worker.Configuration;

namespace Catalog.Sync.Worker.Tests.Configuration;

public sealed class WordPressOptionsValidatorTests
{
    private readonly WordPressOptionsValidator _validator = new();

    [Fact]
    public void Validate_AcceptsHttps()
    {
        var result = _validator.Validate(null, CreateValidOptions("https://catalog.example.test"));

        Assert.True(result.Succeeded);
    }

    [Fact]
    public void Validate_AcceptsExplicitlyAllowedLoopbackHttp()
    {
        var options = CreateValidOptions("http://localhost:8080");
        options.AllowInsecureHttpForLocalDevelopment = true;

        var result = _validator.Validate(null, options);

        Assert.True(result.Succeeded);
    }

    [Theory]
    [InlineData("http://catalog.example.test", true)]
    [InlineData("http://localhost:8080", false)]
    public void Validate_RejectsUnsafeHttp(string baseUrl, bool allowInsecureHttp)
    {
        var options = CreateValidOptions(baseUrl);
        options.AllowInsecureHttpForLocalDevelopment = allowInsecureHttp;

        var result = _validator.Validate(null, options);

        Assert.True(result.Failed);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(6)]
    public void Validate_RejectsRetryAttemptCountOutsideBoundedRange(int attempts)
    {
        var options = CreateValidOptions("https://catalog.example.test");
        options.MaxRetryAttempts = attempts;

        var result = _validator.Validate(null, options);

        Assert.True(result.Failed);
    }

    private static WordPressOptions CreateValidOptions(string baseUrl)
    {
        return new WordPressOptions
        {
            BaseUrl = baseUrl,
            RunsEndpoint = "/wp-json/catalog-sync/v1/runs",
            Username = "catalog_sync",
            ApplicationPassword = "test-only-password",
            RequestTimeoutSeconds = 60,
        };
    }
}
