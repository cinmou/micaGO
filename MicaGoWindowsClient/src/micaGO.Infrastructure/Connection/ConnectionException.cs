namespace MicaGo.Infrastructure.Connection;

public class ConnectionException(string message, Exception? innerException = null)
    : Exception(message, innerException);

public sealed class CredentialRejectedException() : ConnectionException("The server rejected this device credential. Pair again.");
