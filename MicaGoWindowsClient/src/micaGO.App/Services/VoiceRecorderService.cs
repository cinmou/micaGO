using Windows.Media.Capture;
using Windows.Media.MediaProperties;
using Windows.Storage;

namespace MicaGo.App.Services;

/// <summary>
/// Records microphone audio to an AAC .m4a temp file (the same container the
/// Flutter client sends). One recording at a time; Cancel deletes the file.
/// </summary>
public sealed class VoiceRecorderService : IDisposable
{
    private MediaCapture? _capture;
    private StorageFile? _file;

    public bool IsRecording { get; private set; }

    public async Task StartAsync()
    {
        if (IsRecording) return;
        var directory = Path.Combine(Path.GetTempPath(), "micaGO-voice");
        Directory.CreateDirectory(directory);
        var folder = await StorageFolder.GetFolderFromPathAsync(directory);
        _file = await folder.CreateFileAsync(
            $"voice-{DateTimeOffset.Now:yyyyMMdd-HHmmss}.m4a", CreationCollisionOption.GenerateUniqueName);

        _capture = new MediaCapture();
        await _capture.InitializeAsync(new MediaCaptureInitializationSettings
        {
            StreamingCaptureMode = StreamingCaptureMode.Audio,
        });
        await _capture.StartRecordToStorageFileAsync(
            MediaEncodingProfile.CreateM4a(AudioEncodingQuality.Medium), _file);
        IsRecording = true;
    }

    /// <summary>Stops and returns the recorded file path, or null when nothing was recorded.</summary>
    public async Task<string?> StopAsync()
    {
        if (!IsRecording || _capture is null || _file is null) return null;
        IsRecording = false;
        try
        {
            await _capture.StopRecordAsync();
            return _file.Path;
        }
        finally
        {
            _capture.Dispose();
            _capture = null;
            _file = null;
        }
    }

    public async Task CancelAsync()
    {
        var path = await StopAsync();
        if (path is not null && File.Exists(path))
        {
            try { File.Delete(path); } catch { }
        }
    }

    public void Dispose()
    {
        _capture?.Dispose();
        _capture = null;
        IsRecording = false;
    }
}
