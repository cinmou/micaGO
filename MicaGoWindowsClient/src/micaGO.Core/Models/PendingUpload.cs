namespace MicaGo.Core.Models;

public sealed record PendingUpload(string TempId,string ChatId,string FilePath,string FileName,string MimeType,long Size,long DateCreated,string State="sending",string? Error=null);
