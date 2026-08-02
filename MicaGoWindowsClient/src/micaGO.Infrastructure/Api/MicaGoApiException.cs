namespace MicaGo.Infrastructure.Api;

public sealed class MicaGoApiException(
    string message,
    int? statusCode = null,
    Exception? innerException = null,
    string? code = null)
    : Exception(message, innerException)
{
    public int? StatusCode { get; } = statusCode;
    public string? Code { get; } = code;
}
