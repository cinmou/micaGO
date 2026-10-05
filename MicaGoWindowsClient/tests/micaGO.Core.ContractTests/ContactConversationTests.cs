using MicaGo.Core.Models;

internal static class ContactConversationTests
{
    public static void Run()
    {
        var email = new ChatSummary("email", "Jane", "new email", "now", 2, "J", ServiceLabel:"iMessage", CanSendText:false, UpdatedAt:200, ContactId:"person", HasUnread:true);
        var phone = new ChatSummary("phone", "Jane", "old SMS", "then", 1, "J", ServiceLabel:"SMS", CanSendText:true, UpdatedAt:100, ContactId:"person", HasUnread:true);
        var merged = ContactConversationSemantics.Merge([email,phone], "email");
        Require(merged.PrimaryRouteId=="phone" && merged.CanSendText && merged.ServiceLabel=="SMS", "Disabled saved route must not disable a sendable merged conversation.");
        Require(merged.Preview=="new email" && merged.UpdatedAt==200 && merged.UnreadCount==3, "Newest preview and summed unread belong to the complete route set.");
        Require(ContactConversationSemantics.SameRoutes(merged,["PHONE","email"]), "Route scope comparison must ignore order and casing.");
        Require(!ContactConversationSemantics.SameRoutes(merged,["phone"]), "Splitting must invalidate the current merged history scope.");
        var splitEmail=email with{KeepRoutesSeparate=true};
        var splitPhone=phone with{KeepRoutesSeparate=true};
        Require(splitEmail.ListKey!=splitPhone.ListKey && splitEmail.ContactId==splitPhone.ContactId, "Split conversations need distinct list keys without losing contact identity.");
        var list=new ChatListCollection(); list.Apply([merged],false); list.Apply([splitEmail,splitPhone],false);
        Require(list.Count==2 && list[0].Id=="email" && list[1].Id=="phone", "Splitting must retain both native list rows.");
        list.Apply([merged],false); Require(list.Count==1, "Re-merging must remove both split rows.");
        var sendableEmail=email with{CanSendText=true};
        Require(ContactConversationSemantics.Merge([sendableEmail,phone],"phone").PrimaryRouteId=="phone", "A valid explicit SMS choice must be preserved.");
        Require(ContactConversationSemantics.Merge([sendableEmail,phone],null).PrimaryRouteId=="email", "Automatic sends should prefer a sendable iMessage route.");
        var newestPhone=phone with{UpdatedAt=300};
        Require(ContactConversationSemantics.Merge([email,newestPhone],null).ListKey==merged.ListKey, "New activity must not replace merged contact identity.");
    }
    private static void Require(bool condition,string message){if(!condition)throw new Exception(message);}
}
