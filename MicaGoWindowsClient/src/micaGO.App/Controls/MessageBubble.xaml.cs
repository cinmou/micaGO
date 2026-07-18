using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using MicaGo.Core.Models;
using Windows.UI;

namespace MicaGo.App.Controls;

public sealed partial class MessageBubble : UserControl
{
    public MessageBubble()
    {
        InitializeComponent();
        DataContextChanged += OnDataContextChanged;
    }

    private void OnDataContextChanged(FrameworkElement sender, DataContextChangedEventArgs args)
    {
        if (args.NewValue is not Message message)
        {
            return;
        }

        Bubble.HorizontalAlignment = message.IsOutgoing ? HorizontalAlignment.Right : HorizontalAlignment.Left;
        var dark = ActualTheme == ElementTheme.Dark;
        Bubble.Background = new SolidColorBrush(message.IsOutgoing
            ? dark ? Color.FromArgb(255, 18, 58, 91) : Color.FromArgb(255, 216, 236, 255)
            : dark ? Color.FromArgb(255, 41, 41, 41) : Color.FromArgb(255, 253, 253, 253));

        SenderText.Text = message.SenderName ?? string.Empty;
        SenderText.Visibility = string.IsNullOrWhiteSpace(message.SenderName) ? Visibility.Collapsed : Visibility.Visible;
        BodyText.Text = message.Text;
        BodyText.Visibility = string.IsNullOrWhiteSpace(message.Text) ? Visibility.Collapsed : Visibility.Visible;
        AttachmentText.Text = message.AttachmentLabel ?? string.Empty;
        AttachmentPanel.Visibility = string.IsNullOrWhiteSpace(message.AttachmentLabel) ? Visibility.Collapsed : Visibility.Visible;
        FooterText.Text = message.IsOutgoing ? message.Footer : message.SentAt;
    }
}
