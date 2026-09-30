using MicaGo.Core.Models;

internal static class ChatUnreadTests
{
    public static void Run()
    {
        void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
        Check(ChatUnreadSemantics.Badge(false, 9, false)==UnreadBadgeKind.None,"stale count showed an unread badge");
        Check(ChatUnreadSemantics.Badge(true, 9, true)==UnreadBadgeKind.Dot,"muted chat showed a number");
        Check(ChatUnreadSemantics.Badge(true, 0, false)==UnreadBadgeKind.Dot,"watermark unread lost its dot");
        Check(ChatUnreadSemantics.Badge(true, 3, false)==UnreadBadgeKind.Count,"incoming count lost");
        var a=new ChatSummary("a","A","","",0,"A",UpdatedAt:100);
        var b=new ChatSummary("b","B","","",0,"B",UpdatedAt:100);
        a=ChatUnreadSemantics.Advance(a,110,false,false,true);
        b=ChatUnreadSemantics.Advance(b,120,false,false,true);
        a=ChatUnreadSemantics.Advance(a,130,true,false,true);
        Check(!a.HasUnread && b.HasUnread && b.UnreadCount==1,"outgoing cleared another route's unread");
        b=ChatUnreadSemantics.Advance(b,120,false,false,false);
        Check(b.UnreadCount==1,"replayed message incremented count");
        b=ChatUnreadSemantics.Advance(b,90,true,false,true);
        Check(b.HasUnread && b.UpdatedAt==120,"old outgoing cleared newer unread");
        b=ChatUnreadSemantics.Advance(b,140,false,true,true);
        Check(!b.HasUnread && b.UnreadCount==0,"open thread kept its unread marker");
    }
}
