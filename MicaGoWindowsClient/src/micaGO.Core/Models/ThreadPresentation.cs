using System.Globalization;

namespace MicaGo.Core.Models;

public static class ThreadPresentation
{
    private static readonly IReadOnlyDictionary<string,string> Effects=new Dictionary<string,string>
    {
        ["com.apple.MobileSMS.expressivesend.impact"]="Sent with Slam",
        ["com.apple.MobileSMS.expressivesend.loud"]="Sent with Loud",
        ["com.apple.MobileSMS.expressivesend.gentle"]="Sent with Gentle",
        ["com.apple.MobileSMS.expressivesend.invisibleink"]="Sent with Invisible Ink",
        ["com.apple.messages.effect.CKEchoEffect"]="Sent with Echo",
        ["com.apple.messages.effect.CKSpotlightEffect"]="Sent with Spotlight",
        ["com.apple.messages.effect.CKHappyBirthdayEffect"]="Sent with Balloons",
        ["com.apple.messages.effect.CKConfettiEffect"]="Sent with Confetti",
        ["com.apple.messages.effect.CKHeartEffect"]="Sent with Love",
        ["com.apple.messages.effect.CKLasersEffect"]="Sent with Lasers",
        ["com.apple.messages.effect.CKFireworksEffect"]="Sent with Fireworks",
        ["com.apple.messages.effect.CKSparklesEffect"]="Sent with Celebration"
    };

    public static IReadOnlyList<Message> Build(IEnumerable<Message> source,bool isGroup,string language)
    {
        var raw=source.Where(row=>!row.IsSeparator)
            .OrderBy(row=>row.DateCreated).ThenBy(row=>row.SourceRowId)
            .ThenBy(row=>row.ChatId,StringComparer.OrdinalIgnoreCase).ThenBy(row=>row.Id,StringComparer.OrdinalIgnoreCase).ToList();
        var byId=raw.Where(row=>!row.IsReaction).GroupBy(row=>(row.ChatId,row.Id)).ToDictionary(group=>group.Key,group=>group.Last());
        var consumed=new HashSet<(string ChatId,string Id)>();
        foreach(var associated in raw.Where(row=>row.AssociatedMessageType>0&&!string.IsNullOrWhiteSpace(row.AssociatedMessageGuid)))
        {
            var targetId=Target(associated.AssociatedMessageGuid);var targetKey=(associated.ChatId,targetId??string.Empty);if(targetId is null||!byId.TryGetValue(targetKey,out var target))continue;
            if(associated.AssociatedMessageType==1000&&associated.Media.Count>0)
            {
                byId[targetKey]=target with{Attachments=target.Media.Concat(associated.Media).DistinctBy(item=>item.Id).ToArray()};consumed.Add((associated.ChatId,associated.Id));continue;
            }
            var emoji=ReactionEmoji(associated.AssociatedMessageType);if(emoji is null)continue;
            var reactions=(target.Reactions??[]).ToList();if(associated.AssociatedMessageType>=3000)reactions.RemoveAll(value=>value==emoji);else if(!reactions.Contains(emoji))reactions.Add(emoji);
            byId[targetKey]=target with{Reactions=reactions};consumed.Add((associated.ChatId,associated.Id));
        }

        var visible=new List<Message>();
        foreach(var original in raw)
        {
            if(consumed.Contains((original.ChatId,original.Id))||IsKeptAudioNotice(original)||IsInteractiveUpdate(original))continue;
            var row=byId.GetValueOrDefault((original.ChatId,original.Id),original);var system=IsSystem(row);
            if(!string.IsNullOrWhiteSpace(row.ReplyToGuid))
            {
                var targetId=Target(row.ReplyToGuid);var preview=targetId is not null&&byId.TryGetValue((row.ChatId,targetId),out var reply)?ReplyLabel(reply):"Original message unavailable";
                row=row with{ReplyPreview=preview};
            }
            if(system)row=row with{GroupTitle=SystemLabel(row),IsPresentationSystem=true};
            if(system&&visible.Count>0&&visible[^1].IsPresentationSystem)
            {
                visible[^1]=row with{MergedSystemCount=visible[^1].MergedSystemCount+1};continue;
            }
            visible.Add(row);
        }

        var latestOutgoing=visible.FindLastIndex(row=>row.IsOutgoing&&!row.IsPresentationSystem);
        var latestRead=visible.FindLastIndex(row=>row.IsOutgoing&&row.DeliveryState==MessageDeliveryState.Read&&!row.IsPresentationSystem);
        var latestDelivered=visible.FindLastIndex(row=>row.IsOutgoing&&row.DeliveryState==MessageDeliveryState.Delivered&&!row.IsPresentationSystem);
        if(latestRead>latestDelivered)latestDelivered=-1;
        var result=new List<Message>();DateTime? lastDay=null;long? lastAt=null;
        for(var i=0;i<visible.Count;i++)
        {
            var row=visible[i];var at=row.DateCreated>0?DateTimeOffset.FromUnixTimeMilliseconds(row.DateCreated).LocalDateTime:(DateTime?)null;
            if(at is{} date&&(lastDay is null||date.Date!=lastDay.Value.Date||lastAt is null||row.DateCreated-lastAt.Value>=TimeSpan.FromHours(1).TotalMilliseconds))
            {result.Add(new Message("separator-"+row.PresentationKey,row.ChatId,"","",false,MessageDeliveryState.Delivered,IsSeparator:true,SeparatorLabel:Timestamp(date,language)));lastDay=date.Date;}
            if(row.DateCreated>0)lastAt=row.DateCreated;
            var previous=i>0?visible[i-1]:null;var next=i+1<visible.Count?visible[i+1]:null;var compactPrevious=SameRun(previous,row);var compactNext=SameRun(row,next);
            var body=MessageSemantics.VisibleText(row.Text);var bigEmoji=row.Media.Count==0&&IsBigEmoji(body);var stickerOnly=row.Media.Count>0&&row.Media.All(item=>item.IsStickerLike)&&body.Length==0;
            var incomingGroup=isGroup&&!row.IsOutgoing&&!row.IsPresentationSystem;var sameSenderPrevious=incomingGroup&&SameSender(previous,row);var sameSenderNext=incomingGroup&&SameSender(row,next);
            result.Add(row with
            {
                CompactWithPrevious=compactPrevious,CompactWithNext=compactNext,ShowBubbleTail=!row.IsPresentationSystem&&(!compactNext||(next is not null&&IsBigEmoji(MessageSemantics.VisibleText(next.Text)))),
                ShowFooter=row.IsOutgoing&&!row.IsPresentationSystem&&(row.IsEdited||(!isGroup&&(i==latestOutgoing||i==latestRead||i==latestDelivered))),IsBigEmoji=bigEmoji,IsStickerOnly=stickerOnly,
                ShowSenderLabel=incomingGroup&&!sameSenderPrevious,ShowSenderAvatar=incomingGroup&&!sameSenderNext,
                EffectLabel=row.IsPresentationSystem?null:Effect(row.ExpressiveSendStyleId),ReserveSenderAvatarSpace=incomingGroup
            });
        }
        return result;
    }

    private static bool IsSystem(Message row)=>row.IsRetracted||row.IsServiceEvent||row.IsReaction||row.SemanticKind is "deleted" or "unavailable" or "missing_attachment_rows" or "empty_edited_residue"||MessageSemantics.VisibleText(row.Text).Length==0&&row.Media.Count==0&&string.IsNullOrWhiteSpace(row.BalloonBundleId);
    private static bool IsInteractiveUpdate(Message row)=>row.AssociatedMessageType>=4000&&!string.IsNullOrWhiteSpace(row.AssociatedMessageGuid)&&!string.IsNullOrWhiteSpace(row.BalloonBundleId);
    private static bool IsKeptAudioNotice(Message row)=>row.ItemType==5&&!string.IsNullOrWhiteSpace(row.Subject);
    private static string SystemLabel(Message row)
    {
        var text=MessageSemantics.VisibleText(row.Text);if(row.IsRetracted||row.SemanticKind is "missing_attachment_rows" or "empty_edited_residue")return row.IsOutgoing?"You unsent a message":$"{DisplaySender(row)} unsent a message";
        if(row.IsServiceEvent)return text.Length>0?text:"Conversation event";if(row.IsReaction){var emoji=ReactionEmoji(row.AssociatedMessageType)??"";return row.AssociatedMessageType>=3000?$"Removed a {emoji} reaction":$"{emoji} Reacted to a message";}
        return row.SemanticKind=="deleted"?"Message deleted":row.SemanticKind=="unavailable"?"Message unavailable":"Unsupported message";
    }
    private static string ReplyLabel(Message row){var sender=row.IsOutgoing?"You":DisplaySender(row);var text=MessageSemantics.VisibleText(row.Text);return $"{sender}: {(text.Length>0?text:row.AttachmentLabel??"Attachment")}";}
    private static string DisplaySender(Message row)=>string.IsNullOrWhiteSpace(row.SenderName)?row.SenderIdentity??"Unknown":row.SenderName;
    private static bool SameRun(Message? left,Message? right)=>left is not null&&right is not null&&!left.IsPresentationSystem&&!right.IsPresentationSystem&&left.IsOutgoing==right.IsOutgoing&&(left.IsOutgoing||Identity(left)==Identity(right))&&left.DateCreated>0&&right.DateCreated>0&&Math.Abs(right.DateCreated-left.DateCreated)<=TimeSpan.FromMinutes(5).TotalMilliseconds;
    private static bool SameSender(Message? left,Message? right)=>left is not null&&right is not null&&!left.IsOutgoing&&!right.IsOutgoing&&Identity(left).Length>0&&Identity(left)==Identity(right)&&left.DateCreated>0&&right.DateCreated>0&&Math.Abs(right.DateCreated-left.DateCreated)<=TimeSpan.FromMinutes(5).TotalMilliseconds;
    private static string Identity(Message row)=>(row.SenderIdentity??row.SenderName??string.Empty).Trim().ToLowerInvariant();
    /// <summary>Normalises an associated/reply guid ("p:0/GUID", "bp:GUID") to the bare message guid.</summary>
    public static string? NormalizeTarget(string? value){var raw=value?.Trim();if(string.IsNullOrEmpty(raw))return null;if(raw.StartsWith("p:",StringComparison.Ordinal)||raw.StartsWith("bp:",StringComparison.Ordinal))raw=raw[(raw.IndexOf(':')+1)..];var slash=raw.IndexOf('/');if(slash>=0)raw=raw[(slash+1)..];return raw.TrimStart('+');}
    private static string? Target(string? value)=>NormalizeTarget(value);
    private static string? ReactionEmoji(int code)=>(code%1000) switch{0=>"❤️",1=>"👍",2=>"👎",3=>"😂",4=>"‼️",5=>"❓",_=>null};
    private static string? Effect(string? id)=>string.IsNullOrWhiteSpace(id)?null:Effects.GetValueOrDefault(id,"Sent with an effect");
    private static bool IsBigEmoji(string text){if(string.IsNullOrWhiteSpace(text))return false;var elements=StringInfo.GetTextElementEnumerator(text);var count=0;while(elements.MoveNext()){var element=elements.GetTextElement();if(string.IsNullOrWhiteSpace(element))continue;count++;if(count>3||!element.EnumerateRunes().Any(r=>r.Value is >=0x1F000 and <=0x1FAFF or >=0x2600 and <=0x27BF or >=0x1F1E6 and <=0x1F1FF or 0xE50A))return false;}return count is>=1 and<=3;}
    private static string Timestamp(DateTime value,string language){var culture=language switch{"zh-Hans"=>CultureInfo.GetCultureInfo("zh-CN"),"zh-Hant"=>CultureInfo.GetCultureInfo("zh-TW"),_=>CultureInfo.CurrentCulture};var time=value.ToString("t",culture);var days=(DateTime.Today-value.Date).Days;if(days<=0)return time;if(days==1)return (language.StartsWith("zh",StringComparison.Ordinal)?"昨天 ":"Yesterday ")+time;if(days<7)return value.ToString("dddd",culture)+" "+time;return value.ToString("d",culture)+" "+time;}
}
