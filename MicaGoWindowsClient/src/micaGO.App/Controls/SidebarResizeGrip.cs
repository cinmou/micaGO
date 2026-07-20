using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace MicaGo.App.Controls;

/// <summary>
/// Thin native control that owns the standard horizontal-resize cursor.
/// </summary>
public sealed class SidebarResizeGrip : Control
{
    private bool _pressed;

    public SidebarResizeGrip()
    {
        // Creating an InputSystemCursor while XAML is still activating the
        // control can fail with E_FAIL on unpackaged Release builds. Defer it
        // until the control is connected to a XamlRoot; dragging itself does
        // not depend on the optional cursor hint.
        Loaded += (_, _) =>
        {
            try { ProtectedCursor ??= InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast); }
            catch (Exception) { }
        };
    }

    protected override void OnPointerEntered(PointerRoutedEventArgs e)
    {
        base.OnPointerEntered(e);
        VisualStateManager.GoToState(this, _pressed ? "Pressed" : "PointerOver", true);
    }

    protected override void OnPointerExited(PointerRoutedEventArgs e)
    {
        base.OnPointerExited(e);
        if (!_pressed) VisualStateManager.GoToState(this, "Normal", true);
    }

    protected override void OnPointerPressed(PointerRoutedEventArgs e)
    {
        base.OnPointerPressed(e);
        _pressed = true;
        VisualStateManager.GoToState(this, "Pressed", true);
    }

    protected override void OnPointerReleased(PointerRoutedEventArgs e)
    {
        base.OnPointerReleased(e);
        _pressed = false;
        VisualStateManager.GoToState(this, "PointerOver", true);
    }

    protected override void OnPointerCaptureLost(PointerRoutedEventArgs e)
    {
        base.OnPointerCaptureLost(e);
        _pressed = false;
        VisualStateManager.GoToState(this, "Normal", true);
    }
}
