using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

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
            content.Children.Add(new Image
            {
                Width = 20,
                Height = 20,
                Stretch = Stretch.Uniform,
                Source = new BitmapImage(new Uri(logoPath, UriKind.Absolute)),
            });
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
}
