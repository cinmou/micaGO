using MicaGo.Core.Models;

namespace MicaGo.Infrastructure.Api;

public static class SendOutcome
{
    public static MessageDeliveryState FromException(Exception error, CancellationToken cancellationToken=default) => error switch
    {
        MicaGoApiException {Code:"send_confirmation_timeout"} => MessageDeliveryState.Sent,
        MicaGoApiException {StatusCode:202} => MessageDeliveryState.Sent,
        HttpRequestException => MessageDeliveryState.AwaitingConfirmation,
        TimeoutException => MessageDeliveryState.AwaitingConfirmation,
        OperationCanceledException => MessageDeliveryState.AwaitingConfirmation,
        MicaGoApiException {StatusCode:502 or 503 or 504} => MessageDeliveryState.AwaitingConfirmation,
        _ => MessageDeliveryState.Failed,
    };
}
