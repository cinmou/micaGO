using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using MicaGo.App.Services;
using MicaGo.Infrastructure.Connection;
using Windows.Graphics.Imaging;
using Windows.Media.Capture;
using Windows.Media.Capture.Frames;
using Windows.Media.MediaProperties;
using Windows.Storage;

namespace MicaGo.App.Views;

/// <summary>Optional native camera capture; ZXing owns QR recognition.</summary>
internal sealed class PairingQrScanner
{
    private readonly CancellationTokenSource _shutdown = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly Image _preview = new() { Height = 240, Stretch = Stretch.Uniform };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap };
    private readonly SoftwareBitmapSource _imageSource = new();
    private MediaCapture? _capture;
    private MediaFrameReader? _reader;
    private ContentDialog? _dialog;
    private Task? _starting;
    private bool _closed, _processing;
    private string? _result;

    public async Task<string?> ShowAsync(XamlRoot root)
    {
        var l = AppServices.Current.Localization;
        _preview.Source = _imageSource;
        _status.Text = l["scanStarting"];
        var content = new StackPanel { Spacing = 12 };
        content.Children.Add(_preview); content.Children.Add(_status);
        _dialog = new ContentDialog { XamlRoot = root, Title = l["scanQr"], Content = content, CloseButtonText = l["cancel"] };
        _timer.Tick += ReadFrame;
        _dialog.Unloaded += (_, _) => { if (_closed) return; _closed = true; _shutdown.Cancel(); _timer.Stop(); };
        _dialog.Opened += (_, _) => _starting = StartAsync();
        try { await _dialog.ShowAsync(); return _result; }
        finally
        {
            _closed = true; _shutdown.Cancel(); _timer.Stop(); _timer.Tick -= ReadFrame;
            if (_starting is not null) await _starting;
            if (_reader is not null) { try { await _reader.StopAsync(); } catch { } _reader.Dispose(); }
            _capture?.Dispose();
            _preview.Source = null; _shutdown.Dispose();
        }
    }

    private async Task StartAsync()
    {
        try
        {
            var groups = await MediaFrameSourceGroup.FindAllAsync().AsTask(_shutdown.Token);
            if (_closed) return;
            var selected = groups.Select(group => new { Group = group, Source = group.SourceInfos.FirstOrDefault(source => source.SourceKind == MediaFrameSourceKind.Color && (source.MediaStreamType == MediaStreamType.VideoPreview || source.MediaStreamType == MediaStreamType.VideoRecord)) }).FirstOrDefault(item => item.Source is not null);
            if (selected is null) throw new InvalidOperationException();
            _capture = new MediaCapture();
            await _capture.InitializeAsync(new MediaCaptureInitializationSettings
            {
                SourceGroup = selected.Group, SharingMode = MediaCaptureSharingMode.SharedReadOnly,
                MemoryPreference = MediaCaptureMemoryPreference.Cpu, StreamingCaptureMode = StreamingCaptureMode.Video,
            }).AsTask(_shutdown.Token);
            if (_closed) return;
            var source = _capture.FrameSources[selected.Source!.Id];
            var format = source.CurrentFormat.VideoFormat;
            var scale = Math.Min(1d, 1280d / Math.Max(format.Width, format.Height));
            _reader = await _capture.CreateFrameReaderAsync(source, MediaEncodingSubtypes.Argb32,
                new BitmapSize { Width = (uint)Math.Max(1, format.Width * scale), Height = (uint)Math.Max(1, format.Height * scale) }).AsTask(_shutdown.Token);
            if (_closed) return;
            _reader.AcquisitionMode = MediaFrameReaderAcquisitionMode.Realtime;
            if (await _reader.StartAsync().AsTask(_shutdown.Token) != MediaFrameReaderStartStatus.Success) throw new InvalidOperationException();
            if (_closed) return;
            _status.Text = AppServices.Current.Localization["qrHint"];
            _timer.Start();
        }
        catch
        {
            if (!_closed) _status.Text = AppServices.Current.Localization["cameraUnavailable"];
        }
    }

    private async void ReadFrame(object? sender, object e)
    {
        if (_closed || _processing || _reader is null) return;
        _processing = true;
        try
        {
            using var frame = _reader.TryAcquireLatestFrame();
            using var raw = frame?.VideoMediaFrame?.SoftwareBitmap;
            if (raw is null) return;
            using var bitmap = SoftwareBitmap.Convert(raw, BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied);
            var bytes = new byte[checked(bitmap.PixelWidth * bitmap.PixelHeight * 4)];
            bitmap.CopyToBuffer(bytes.AsBuffer());
            var width = bitmap.PixelWidth; var height = bitmap.PixelHeight;
            await _imageSource.SetBitmapAsync(bitmap);
            var value = await Task.Run(() => PairingQrDecoder.Decode(bytes, width, height));
            if (_closed || value is null) return;
            _result = value; _timer.Stop(); _dialog?.Hide();
        }
        catch { if (!_closed) _status.Text = AppServices.Current.Localization["cameraUnavailable"]; }
        finally { _processing = false; }
    }

    public static async Task<string?> ReadImageAsync(StorageFile file)
    {
        var properties = await file.GetBasicPropertiesAsync();
        if (properties.Size > 20 * 1024 * 1024) return null;
        using var stream = await file.OpenReadAsync();
        var decoder = await BitmapDecoder.CreateAsync(stream);
        if (decoder.PixelWidth == 0 || decoder.PixelHeight == 0 || (long)decoder.PixelWidth * decoder.PixelHeight > 100_000_000) return null;
        var scale = Math.Min(1d, 2048d / Math.Max(decoder.PixelWidth, decoder.PixelHeight));
        var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore,
            new BitmapTransform { ScaledWidth = (uint)(decoder.PixelWidth * scale), ScaledHeight = (uint)(decoder.PixelHeight * scale) },
            ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
        var width = (int)(decoder.PixelWidth * scale); var height = (int)(decoder.PixelHeight * scale);
        return await Task.Run(() => PairingQrDecoder.Decode(pixels.DetachPixelData(), width, height));
    }
}
