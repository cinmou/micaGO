namespace MicaGo.Infrastructure.Connection;

public sealed class ConnectionException(string message, Exception? innerException = null)
    : Exception(message, innerException);
