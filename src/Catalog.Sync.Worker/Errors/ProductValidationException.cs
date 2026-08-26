namespace Catalog.Sync.Worker.Errors;

public sealed class ProductValidationException : Exception
{
    public ProductValidationException(string message)
        : base(message)
    {
    }
}
