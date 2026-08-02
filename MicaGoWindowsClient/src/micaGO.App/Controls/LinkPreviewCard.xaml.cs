using System.Collections.Concurrent;
using System.Net.Http.Headers;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using MicaGo.Core.Models;

namespace MicaGo.App.Controls;

/// <summary>Metadata-rich URL card matching the Flutter client's UrlPreviewCard.</summary>
public sealed partial class LinkPreviewCard : UserControl
{
    private static readonly HttpClient Http = CreateHttpClient();
    private static readonly ConcurrentDictionary<string, Task<LinkPreviewMetadata>> Cache = new(StringComparer.OrdinalIgnoreCase);
    private readonly string _url;
    private readonly bool _compact;
    private readonly double _maxWidth;

    public LinkPreviewCard(string rawUrl, bool compact = false)
    {
        InitializeComponent();
        _url = LinkPreviewSemantics.NormalizeUrl(rawUrl) ?? rawUrl;
        _compact = compact;
        _maxWidth = compact ? 260 : 320;
        Card.MinWidth = compact ? 170 : 210;
        Card.MaxWidth = _maxWidth;
        PreviewImage.Width = _maxWidth;
        DescriptionText.MaxLines = compact ? 1 : 3;
        _ = LoadAsync();
    }

    private async Task LoadAsync()
    {
        LinkPreviewMetadata metadata;
        try
        {
            if (Cache.Count > 200) Cache.Clear();
            metadata = await Cache.GetOrAdd(_url, FetchAsync);
        }
        catch
        {
            metadata = new LinkPreviewMetadata(_url);
        }

        if (!metadata.HasDisplayContent)
        {
            Visibility = Visibility.Collapsed;
            return;
        }

        LoadingPanel.Visibility = Visibility.Collapsed;
        MetadataPanel.Visibility = Visibility.Visible;
        TitleText.Text = metadata.Title ?? metadata.Host;
        DescriptionText.Text = metadata.Description ?? string.Empty;
        DescriptionText.Visibility = string.IsNullOrWhiteSpace(metadata.Description) ? Visibility.Collapsed : Visibility.Visible;
        SiteText.Text = metadata.SiteName ?? metadata.Host;

        if (metadata.ImageUrl is { Length: > 0 } imageUrl && Uri.TryCreate(imageUrl, UriKind.Absolute, out var imageUri))
        {
            ImageClip.Visibility = Visibility.Visible;
            PreviewImage.Source = new BitmapImage(imageUri);
        }
    }

    private static async Task<LinkPreviewMetadata> FetchAsync(string url)
    {
        using var response = await Http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
        var contentType = response.Content.Headers.ContentType?.MediaType ?? string.Empty;
        if (contentType.StartsWith("image/", StringComparison.OrdinalIgnoreCase))
        {
            return new LinkPreviewMetadata(url, ImageUrl: url);
        }
        if (!response.IsSuccessStatusCode) return new LinkPreviewMetadata(url);
        var html = await response.Content.ReadAsStringAsync();
        return LinkPreviewSemantics.ParseHtml(url, html);
    }

    private void PreviewImage_ImageOpened(object sender, RoutedEventArgs e)
    {
        if (PreviewImage.Source is not BitmapImage bitmap || bitmap.PixelHeight <= 0) return;
        var aspect = Math.Clamp((double)bitmap.PixelWidth / bitmap.PixelHeight, 0.45, 2.4);
        var minWidth = _compact ? 170d : 210d;
        var width = aspect >= 1 ? _maxWidth : Math.Clamp(_maxWidth * aspect, minWidth, _maxWidth);
        PreviewImage.Width = width;
        PreviewImage.Height = Math.Clamp(width / aspect, 90, _compact ? 220 : 300);
    }

    private void PreviewImage_ImageFailed(object sender, ExceptionRoutedEventArgs e) => ImageClip.Visibility = Visibility.Collapsed;

    private async void Card_Tapped(object sender, TappedRoutedEventArgs e)
    {
        e.Handled = true;
        if (Uri.TryCreate(_url, UriKind.Absolute, out var uri)) await Windows.System.Launcher.LaunchUriAsync(uri);
    }

    private static HttpClient CreateHttpClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(6) };
        client.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("micaGO", "1.0"));
        return client;
    }
}
