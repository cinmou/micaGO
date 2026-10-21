namespace MicaGo.Core.Models;

public sealed record PendingSend(string TempId,string ChatId,string FilePath,string FileName,string MimeType,long Size,long DateCreated,string State="queued",string? Error=null,string? Text=null,bool IsAudioMessage=false)
{
    public bool IsText => Text is not null;
    public Message ToMessage(bool active=false) => new(TempId,ChatId,Text??"",DateTimeOffset.FromUnixTimeMilliseconds(DateCreated).LocalDateTime.ToString("HH:mm"),true,
        State=="failed"||State=="queued"&&!active?MessageDeliveryState.Failed:State=="sent_unconfirmed"?MessageDeliveryState.Sent:(State=="sending"||State=="queued")&&active?MessageDeliveryState.Sending:MessageDeliveryState.AwaitingConfirmation,
        AttachmentLabel:IsText?null:FileName,DateCreated:DateCreated,Attachments:IsText?[]:[new Attachment(TempId,FileName,MimeType,Size,IsVoiceMessage:IsAudioMessage)],IsPending:true,ErrorText:Error,PresentationId:TempId);
}
