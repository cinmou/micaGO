using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace MicaGo.App.Controls;

internal static class TitleBarBrand
{
    public static FrameworkElement Create()
    {
        var content = new StackPanel
        {
            Margin = new Thickness(12, 0, 0, 0),
            Orientation = Orientation.Horizontal,
            VerticalAlignment = VerticalAlignment.Center,
            IsHitTestVisible = false,
            Spacing = 7,
        };
        var logoPath = Path.Combine(AppContext.BaseDirectory, "Assets", "micaGO.Windows.png");
        if (File.Exists(logoPath))
        {
            var logo = new Image
            {
                Width = 20,
                Height = 20,
                Stretch = Stretch.Uniform,
            };
            content.Children.Add(logo);
            _ = LoadLogoAsync(logo, logoPath);
        }
        content.Children.Add(new TextBlock
        {
            Text = "micaGO",
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 12,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
        });
        return content;
    }

    private static async Task LoadLogoAsync(Image target, string path)
    {
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(path);
            using IRandomAccessStream stream = await file.OpenAsync(FileAccessMode.Read);
            var source = new BitmapImage();
            await source.SetSourceAsync(stream);
            target.Source = source;
        }
        catch
        {
            // A missing or damaged optional title-bar asset must never prevent
            // an unpackaged WinUI host from opening.
            target.Visibility = Visibility.Collapsed;
        }
    }
}
