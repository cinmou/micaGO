using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using MicaGo.App.Services;
using MicaGo.App.Views;
using Windows.Graphics;

namespace MicaGo.App;

public sealed partial class MainWindow : Window
{
    public MainWindow()
    {
        InitializeComponent();
        if (AppWindowTitleBar.IsCustomizationSupported())
        {
            ExtendsContentIntoTitleBar = true;
            SetTitleBar(AppTitleBar);
            AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Collapsed;
        }
        else
        {
            TitleBarRow.Height = new GridLength(0);
        }

        SystemBackdrop = new MicaBackdrop { Kind = MicaKind.BaseAlt };
        AppWindow.Resize(new SizeInt32(1180, 760));

        Closed += (_, _) => AppServices.Current.Dispose();
        RootFrame.Navigate(typeof(ConnectionPage));
    }
}
