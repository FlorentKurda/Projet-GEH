namespace Catalog.Sync.Worker.Errors;

public sealed class ProductSourceException : Exception
{
    public ProductSourceException(string message)
        : base(message)
    {
    }

    public ProductSourceException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
