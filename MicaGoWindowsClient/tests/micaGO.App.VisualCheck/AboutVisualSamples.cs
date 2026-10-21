using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using MicaGo.App.Services;

namespace MicaGo.App.Views;

public sealed partial class SettingsPage
{
    internal void LoadAppearanceVisualSample()
    {
        Loaded-=SettingsPage_Loaded;ApplySection("appearance");var l=AppServices.Current.Localization;
        AppearanceHeader.Text=l["appearance"];ThemeLabel.Text=l["theme"];ThemePicker.SelectedIndex=0;
        ChatBackgroundLabel.Text=l["chatBackground"];ChatBackgroundStatus.Text=l["defaultMicaBackground"];
        ChooseBackgroundButton.Content=l["choose"];ClearBackgroundButton.Content=l["removeBackground"];
        BubbleColorLabel.Text=l["bubbleColor"];BubbleColorDescription.Text=l["bubbleColorDescription"];
        BubbleColorPickLabel.Text=l["presetColors"];BubbleColorButtonText.Text=l["moreColors"];
        BubbleColorModePicker.SelectedIndex=1;LocalizePickers(l);BuildBubbleSwatches();
        EmojiHeader.Text=l["emoji"];TwemojiFlagsLabel.Text=l["twemojiFlags"];TwemojiFlagsDescription.Text=l["twemojiFlagsDescription"];
    }
    internal bool ColorControlsFit=>BubbleColorModePicker.ActualWidth>0&&BubbleColorModePicker.TransformToVisual(BubbleColorHeader).TransformPoint(new Windows.Foundation.Point()).X+BubbleColorModePicker.ActualWidth<=BubbleColorHeader.ActualWidth+1;
    internal void SetSampleColorMode(int mode)=>BubbleColorModePicker.SelectedIndex=mode;
    internal bool CustomColorsVisible=>CustomBubbleColorPanel.Visibility==Visibility.Visible;
    internal int ColorModeRow=>Grid.GetRow(BubbleColorModePicker);
    internal void LoadAboutVisualSample()
    {
        Loaded-=SettingsPage_Loaded;NavigationCacheMode=NavigationCacheMode.Required;
        ApplySection("about");var l=AppServices.Current.Localization;
        AboutHeader.Text=l["about"];AboutSubtitleText.Text=l["aboutSubtitle"];
        AboutVersionText.Text=string.Format(l["version"],"0.88.0");AboutGitHubLabel.Text=l["viewOnGitHub"];
        AboutUpdateLabel.Text=l["checkUpdates"];AboutUpdateStatus.Text=l["updateCheckNow"];
        AboutUpdateButton.Content=l["updateCheckButton"];AboutOpenSourceLabel.Text=l["openSource"];
    }
    internal bool HasCompactNoticesLink=>AboutOpenSourceLink.ActualWidth>0&&AboutOpenSourceLink.ActualHeight<40;
}

internal static class AboutVisualCheck
{
    private static Window? _window;
    private static Window? _appearanceWindow;
    internal static void Run()
    {
        AppServices.Current.Localization.SetLanguage("en");
        var frame=new Frame();
        frame.Navigated+=(_,_)=>{if(frame.Content is SettingsPage page)page.LoadAboutVisualSample();};
        frame.Navigate(typeof(SettingsPage),new ShellNavigationContext(null!,null,"about"));
        AppServices.Current.Localization.ApplyTypography(frame);
        _window=new Window{Title="micaGO About Preview",Content=frame,SystemBackdrop=new Microsoft.UI.Xaml.Media.MicaBackdrop()};
        frame.RequestedTheme=ElementTheme.Light;
        _window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1500,1100));_window.Activate();
        var appearance=new SettingsPage();appearance.LoadAppearanceVisualSample();
        AppServices.Current.Localization.ApplyTypography(appearance);appearance.RequestedTheme=ElementTheme.Light;
        _appearanceWindow=new Window{Title="micaGO Appearance Preview",Content=appearance,SystemBackdrop=new Microsoft.UI.Xaml.Media.MicaBackdrop()};
        _appearanceWindow.AppWindow.Resize(new Windows.Graphics.SizeInt32(1500,1100));_appearanceWindow.Activate();
        var timer=new DispatcherTimer{Interval=TimeSpan.FromSeconds(1)};var phase=0;var results=new List<string>();
        timer.Tick+=(_,_)=>{
            frame.UpdateLayout();
            if(phase++==0) {
                var page=(SettingsPage)frame.Content;
                results.Add($"{(page.HasCompactNoticesLink&&!Descendants(page).OfType<Expander>().Any()?"PASS":"FAIL")} About has a compact link without an attribution expander");
                frame.Navigate(typeof(ThirdPartyNoticesPage));return;
            }
            if(phase==2) {
                var texts=Descendants(frame).OfType<TextBlock>().Select(block=>block.Text).ToArray();
                results.Add($"{(texts.Any(text=>text.Contains("Twemoji"))&&texts.Any(text=>text.Contains("Permission is hereby granted"))?"PASS":"FAIL")} bundled notices load in an independent native page");
                results.Add($"{(!texts.Any(text=>text.Contains("no affiliation"))?"PASS":"FAIL")} no Twitter non-affiliation copy");
                frame.GoBack();return;
            }
            if(phase==3) {
                results.Add($"{(frame.Content is SettingsPage returnedPage&&returnedPage.HasCompactNoticesLink?"PASS":"FAIL")} native Back returns to About");
                results.Add($"{(appearance.ColorControlsFit&&appearance.ColorModeRow==0?"PASS":"FAIL")} wide color header fits in one row");
                appearance.SetSampleColorMode(0);
                results.Add($"{(!appearance.CustomColorsVisible?"PASS":"FAIL")} system accent hides custom palette");
                appearance.SetSampleColorMode(1);_appearanceWindow.AppWindow.Resize(new Windows.Graphics.SizeInt32(800,1100));return;
            }
            results.Add($"{(appearance.ColorControlsFit&&appearance.ColorModeRow==1&&appearance.CustomColorsVisible?"PASS":"FAIL")} narrow color header wraps without clipping");
            _appearanceWindow.AppWindow.Resize(new Windows.Graphics.SizeInt32(1500,1100));
            File.WriteAllLines(Path.Combine(AppContext.BaseDirectory,"about-check.log"),results);timer.Stop();
        };timer.Start();
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject element)
    {
        yield return element;
        for(var i=0;i<Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(element);i++)
            foreach(var child in Descendants(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(element,i)))yield return child;
    }
}
