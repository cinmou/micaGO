using System.Numerics;
using Microsoft.UI.Composition;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI.ViewManagement;

namespace MicaGo.App.Controls;

// A viewport-owned indicator cannot be recycled into an unrelated row. Selection
// animates; scrolling, resizing and collection reconciliation only re-anchor it.
internal sealed class SidebarSelectionAnimation : IDisposable
{
    private readonly ListView _list;
    private readonly Grid _viewport;
    private readonly Border _indicator;
    private readonly Visual _visual;
    private readonly UISettings _settings = new();
    private ScrollViewer? _scroller;
    private object? _item;
    private Vector2? _position;
    private int _generation;
    private bool _queued;
    private bool _animateQueued;
    private bool _disposed;
    private Size _clipSize;

    public SidebarSelectionAnimation(ListView list, Grid viewport, Border indicator)
    {
        _list = list; _viewport = viewport; _indicator = indicator;
        ElementCompositionPreview.SetIsTranslationEnabled(indicator, true);
        _visual = ElementCompositionPreview.GetElementVisual(indicator);
        _list.SelectionChanged += SelectionChanged;
        _list.ContainerContentChanging += ContainerContentChanging;
        _list.Loaded += Loaded;
        _list.Unloaded += Unloaded;
        _viewport.SizeChanged += SizeChanged;
        _viewport.LayoutUpdated += LayoutUpdated;
    }

    private void Loaded(object sender, RoutedEventArgs args)
    {
        DetachScroller();
        _scroller = FindScroller(_list);
        if (_scroller is not null) _scroller.ViewChanged += ViewChanged;
        if (!_queued) Refresh(false);
    }

    private void Unloaded(object sender, RoutedEventArgs args)
    {
        CancelQueuedSelection();
        DetachScroller();
        Hide();
    }

    private void SelectionChanged(object sender, SelectionChangedEventArgs args) => QueueUpdate(true);

    private void ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        // Virtualized rows may be recycled/recreated without resizing the host.
        // Wait for the native container's deferred content phase before anchoring.
        if (!args.InRecycleQueue && args.Phase == 0)
            args.RegisterUpdateCallback(1, ContainerReady);
    }

    private void ContainerReady(ListViewBase sender, ContainerContentChangingEventArgs args) => QueueUpdate(false);

    private void QueueUpdate(bool animate)
    {
        if (_disposed) return;
        _animateQueued |= animate;
        if (_queued) return;
        _queued = true;
        CompositionTarget.Rendering += SelectionRendering;
    }

    private void SelectionRendering(object? sender, object args)
    {
        CompositionTarget.Rendering -= SelectionRendering;
        var animate = _animateQueued;
        _queued = false;
        _animateQueued = false;
        if (!_disposed) Refresh(animate, onlyIfMoved: !animate);
    }

    private void CancelQueuedSelection()
    {
        CompositionTarget.Rendering -= SelectionRendering;
        _queued = false;
        _animateQueued = false;
    }

    private void SizeChanged(object sender, SizeChangedEventArgs args)
    {
        if (!_queued) Refresh(false, onlyIfMoved: true);
    }
    private void ViewChanged(object? sender, ScrollViewerViewChangedEventArgs args)
    {
        if (!_queued) Refresh(false, onlyIfMoved: true);
    }
    private void LayoutUpdated(object? sender, object args)
    {
        // Let the queued selection pass retain the previous row's position.
        if (!_queued) Refresh(false, onlyIfMoved: true);
    }

    private void Refresh(bool animate, bool onlyIfMoved = false)
    {
        if (_disposed) return;
        var size = new Size(_viewport.ActualWidth, _viewport.ActualHeight);
        if (size != _clipSize) {
            _clipSize = size;
            _viewport.Clip = new RectangleGeometry { Rect = new Rect(new Point(), size) };
        }
        var selected = _list.SelectedItem;
        if (selected is null || _list.SelectionMode != ListViewSelectionMode.Single || !IsVisible()) { Hide(); return; }
        var row = selected as ListViewItem ?? _list.ContainerFromItem(selected) as ListViewItem;
        if (row is null || row.ActualHeight <= 0) { Hide(); return; }

        var origin = row.TransformToVisual(_viewport).TransformPoint(new Point());
        var target = new Vector2((float)origin.X + 4, (float)(origin.Y + (row.ActualHeight - _indicator.Height) / 2));
        if (target.Y + _indicator.Height <= 0 || target.Y >= _viewport.ActualHeight) { Hide(); return; }
        if (onlyIfMoved && ReferenceEquals(selected, _item) && _position is { } same
            && Vector2.DistanceSquared(same, target) < 0.0625f) return;

        var previous = _position;
        var changed = !ReferenceEquals(selected, _item);
        // Pointer selection can lay out the new presenter before SelectionChanged
        // is raised. Never let that passive layout pass consume the old position.
        if (!animate && changed && previous is not null) {
            QueueUpdate(true);
            return;
        }
        _item = selected;
        _position = target;
        _indicator.Visibility = Visibility.Visible;
        var generation = ++_generation;
        _visual.StopAnimation("Translation.Y");
        _visual.StopAnimation("Scale.Y");
        _visual.StopAnimation("CenterPoint.Y");
        _visual.Scale = Vector3.One;
        _visual.CenterPoint = Vector3.Zero;
        Canvas.SetLeft(_indicator, target.X);
        if (!animate || !changed || previous is not { } from || !AnimationsEnabled()
            || Math.Abs(from.X - target.X) > 0.5 || Math.Abs(from.Y - target.Y) < 0.5)
        {
            _visual.Properties.InsertVector3("Translation", new Vector3(0, target.Y, 0));
            return;
        }

        // NavigationView's indicator motion coordinates position, length and
        // pivot: grow toward the destination, switch pivot, then contract.
        // Use WinUI's standard duration resource for this list adaptation.
        var compositor = _visual.Compositor;
        var stretch = compositor.CreateCubicBezierEasingFunction(new Vector2(0.9f, 0.1f), new Vector2(1, 0.2f));
        var settle = compositor.CreateCubicBezierEasingFunction(new Vector2(0.1f, 0.9f), new Vector2(0.2f, 1));
        var step = compositor.CreateStepEasingFunction();
        step.IsFinalStepSingleFrame = true;
        var duration = Application.Current.Resources.TryGetValue("ControlNormalAnimationDuration", out var resource)
            && TimeSpan.TryParse(resource?.ToString(), System.Globalization.CultureInfo.InvariantCulture, out var standard)
            ? standard : TimeSpan.FromMilliseconds(250);
        var top = compositor.CreateScalarKeyFrameAnimation();
        top.InsertKeyFrame(0, from.Y);
        top.InsertKeyFrame(1f / 3, target.Y, step);
        top.Duration = duration;
        var length = compositor.CreateScalarKeyFrameAnimation();
        length.InsertKeyFrame(0, 1);
        length.InsertKeyFrame(1f / 3, 1 + Math.Abs(target.Y - from.Y) / (float)_indicator.Height, stretch);
        length.InsertKeyFrame(1, 1, settle);
        length.Duration = duration;
        var pivot = compositor.CreateScalarKeyFrameAnimation();
        pivot.InsertKeyFrame(0, from.Y < target.Y ? 0 : (float)_indicator.Height);
        pivot.InsertKeyFrame(1, from.Y < target.Y ? (float)_indicator.Height : 0, step);
        pivot.Duration = TimeSpan.FromTicks(duration.Ticks / 3);
        var batch = compositor.CreateScopedBatch(CompositionBatchTypes.Animation);
        batch.Completed += (_, _) => {
            try {
                if (_disposed || generation != _generation) return;
                _visual.StopAnimation("Translation.Y");
                _visual.StopAnimation("Scale.Y");
                _visual.StopAnimation("CenterPoint.Y");
                _visual.Properties.InsertVector3("Translation", new Vector3(0, target.Y, 0));
                _visual.Scale = Vector3.One;
                _visual.CenterPoint = Vector3.Zero;
            }
            finally { batch.Dispose(); }
        };
        _visual.StartAnimation("Translation.Y", top);
        _visual.StartAnimation("Scale.Y", length);
        _visual.StartAnimation("CenterPoint.Y", pivot);
        batch.End();
    }

    private bool AnimationsEnabled()
    {
        try { return _settings.AnimationsEnabled; }
        catch { return false; }
    }

    private bool IsVisible()
    {
        if (!_list.IsLoaded || _viewport.ActualHeight <= 0) return false;
        for (DependencyObject? node = _list; node is not null; node = VisualTreeHelper.GetParent(node))
            if (node is UIElement { Visibility: Visibility.Collapsed }) return false;
        return true;
    }

    private void Hide()
    {
        ++_generation;
        _visual.StopAnimation("Translation.Y");
        _visual.StopAnimation("Scale.Y");
        _visual.StopAnimation("CenterPoint.Y");
        _visual.Scale = Vector3.One;
        _visual.CenterPoint = Vector3.Zero;
        _indicator.Visibility = Visibility.Collapsed;
        _position = null;
        _item = null;
    }

    private static ScrollViewer? FindScroller(DependencyObject parent)
    {
        if (parent is ScrollViewer scroller) return scroller;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
            if (FindScroller(VisualTreeHelper.GetChild(parent, i)) is { } child) return child;
        return null;
    }

    private void DetachScroller()
    {
        if (_scroller is not null) _scroller.ViewChanged -= ViewChanged;
        _scroller = null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        CancelQueuedSelection();
        Hide();
        _disposed = true;
        DetachScroller();
        _list.SelectionChanged -= SelectionChanged;
        _list.ContainerContentChanging -= ContainerContentChanging;
        _list.Loaded -= Loaded;
        _list.Unloaded -= Unloaded;
        _viewport.SizeChanged -= SizeChanged;
        _viewport.LayoutUpdated -= LayoutUpdated;
    }
}
