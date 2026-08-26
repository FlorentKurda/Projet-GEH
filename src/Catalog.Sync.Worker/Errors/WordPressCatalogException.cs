namespace Catalog.Sync.Worker.Errors;

public sealed class WordPressCatalogException : Exception
{
    public WordPressCatalogException(string message)
        : base(message)
    {
    }

    public WordPressCatalogException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
