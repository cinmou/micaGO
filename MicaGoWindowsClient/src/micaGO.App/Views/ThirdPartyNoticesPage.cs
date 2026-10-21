using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Navigation;
using MicaGo.App.Services;

namespace MicaGo.App.Views;

/// <summary>Offline, selectable copies of the notices shipped with this build.</summary>
public sealed partial class ThirdPartyNoticesPage : Page
{
    private ShellNavigationContext? _context;
    public ThirdPartyNoticesPage()
    {
        InitializeComponent();var l=AppServices.Current.Localization;TitleText.Text=l["openSource"];
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(BackButton,l["back"]);
    }
    private void BackButton_Click(object sender,RoutedEventArgs e)
    {
        if(_context is not null)_context.Host.GoBackInDetail();else if(Frame?.CanGoBack==true)Frame.GoBack();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);_context=e.Parameter as ShellNavigationContext;
        if(DocumentsPanel.Children.Count>0)return;
        var l=AppServices.Current.Localization;
        foreach(var (name,file,markdown) in new[]{
            (l["thirdPartyNotices"],"THIRD-PARTY-NOTICES.md",true),
            ("Twemoji · CC BY 4.0","TWEMOJI-LICENSE-GRAPHICS.txt",false),
            ("ZXing.Net · Apache License 2.0","ZXING-LICENSE.txt",false)})
        {
            DocumentsPanel.Children.Add(new TextBlock{Text=name,FontSize=18,FontWeight=Microsoft.UI.Text.FontWeights.SemiBold,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,8,0,0)});
            try
            {
                var text=await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory,file));
                if(markdown)AddNoticeParagraphs(text);
                else DocumentsPanel.Children.Add(Body(text));
            }
            catch(Exception error) when(error is IOException or UnauthorizedAccessException)
            {DocumentsPanel.Children.Add(Body(l["licenseReadFailed"]));}
        }
    }

    private void AddNoticeParagraphs(string text)
    {
        // The bundled notice uses only headings, paragraphs and plain URLs.
        foreach(var paragraph in text.Replace("\r\n","\n").Split("\n\n",StringSplitOptions.RemoveEmptyEntries))
        {
            var value=paragraph.Trim();if(value=="# Third-party notices")continue;
            var heading=value.StartsWith("## ",StringComparison.Ordinal);
            var block=Body(heading?value[3..]:value.Replace("`",string.Empty));
            if(heading){block.FontWeight=Microsoft.UI.Text.FontWeights.SemiBold;block.Margin=new Thickness(0,4,0,0);}
            DocumentsPanel.Children.Add(block);
        }
    }
    private static TextBlock Body(string text)
    {
        var block=new TextBlock{FontSize=14,TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=true};
        var offset=0;
        foreach(System.Text.RegularExpressions.Match match in System.Text.RegularExpressions.Regex.Matches(text,@"https?://[^\s<>""\)]+")) {
            block.Inlines.Add(new Run{Text=text[offset..match.Index]});
            var link=new Hyperlink{NavigateUri=new Uri(match.Value)};link.Inlines.Add(new Run{Text=match.Value});block.Inlines.Add(link);
            offset=match.Index+match.Length;
        }
        block.Inlines.Add(new Run{Text=text[offset..]});return block;
    }
}
