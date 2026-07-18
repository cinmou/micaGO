namespace MicaGo.Infrastructure.Api;

public sealed class MicaGoApiException(
    string message,
    int? statusCode = null,
    Exception? innerException = null)
    : Exception(message, innerException)
{
    public int? StatusCode { get; } = statusCode;
}
