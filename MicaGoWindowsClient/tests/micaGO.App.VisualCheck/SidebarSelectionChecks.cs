using System.Numerics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using MicaGo.Core.Models;
using Windows.Foundation;
using Windows.UI.ViewManagement;

namespace MicaGo.App.Views;

public sealed partial class ShellPage
{
    internal async Task CheckSidebarSelectionAsync(bool settings)
    {
        var results = new List<string>();
        void Check(bool pass, string description) => results.Add($"{(pass ? "PASS" : "FAIL")} {description}");
        try
        {
            var list = settings ? SettingsNavigationList : ChatList;
            var region = settings ? SettingsSelectionRegion : ChatSelectionRegion;
            var indicator = settings ? SettingsSelectionIndicator : ChatSelectionIndicator;
            var visual = ElementCompositionPreview.GetElementVisual(indicator);
            results.Add($"INFO system animations enabled={new UISettings().AnimationsEnabled}");
            ChatListCollection? rows = null;
            if (!settings)
            {
                ChatList.ItemClick -= ChatList_ItemClick;
                var api = System.Reflection.DispatchProxy.Create<MicaGo.Infrastructure.Contracts.IMicaGoApi, NoNetworkMenuApi>();
                _viewModel = new ViewModels.ShellViewModel(DispatcherQueue, api, Services.AppServices.Current);
                rows = _viewModel.Chats;
                rows.Apply(Enumerable.Range(0, 80).Select(i => new ChatSummary($"preview-{i}", $"Preview contact {i}", "Offline animation check", "10:30", 0, "P")).ToArray(), false);
                rows.Mutated += ChatRows_Mutated;
                list.ItemsSource = rows;
            }
            list.SelectedIndex = 0;
            await Task.Delay(500);
            bool Aligned()
            {
                var row = list.SelectedItem as ListViewItem ?? list.ContainerFromItem(list.SelectedItem) as ListViewItem;
                if (row is null || indicator.Visibility != Visibility.Visible) {
                    results.Add($"DETAIL unavailable row={row is not null} indicator={indicator.Visibility} index={list.SelectedIndex}");
                    return false;
                }
                var point = row.TransformToVisual(region).TransformPoint(new Point());
                visual.Properties.TryGetVector3("Translation", out var translation);
                var aligned = Math.Abs(translation.Y - (point.Y + (row.ActualHeight - indicator.Height) / 2)) < 1
                    && Math.Abs(Canvas.GetLeft(indicator) - point.X - 4) < 1
                    && visual.Scale == Vector3.One;
                if(!aligned)results.Add($"DETAIL index={list.SelectedIndex} expected={point.X+4},{point.Y+(row.ActualHeight-indicator.Height)/2} actual={Canvas.GetLeft(indicator)},{translation.Y} scale={visual.Scale}");
                return aligned;
            }
            Check(Aligned(), "initial selected row is aligned");
            list.SelectedIndex = 3;
            // Reproduce the pointer path: a passive layout observes the new
            // SelectedItem before the deferred selection rendering pass runs.
            var animation = settings ? _settingsSelectionAnimation : _chatSelectionAnimation;
            typeof(Controls.SidebarSelectionAnimation)
                .GetMethod("Refresh", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!
                .Invoke(animation, [false, true]);
            await Task.Delay(80);
            Check(!new UISettings().AnimationsEnabled || visual.TryGetAnimationController("Scale.Y") is not null,
                "passive layout cannot consume the selection stretch animation");
            await Task.Delay(400);
            Check(Aligned(), "animation settles on destination");
            foreach (var index in new[] { 0, 4, 1, 3, 2 })
            {
                list.SelectedIndex = index;
                await Task.Delay(60);
            }
            await Task.Delay(400);
            Check(list.SelectedIndex == 2 && Aligned(), "rapid changes settle on the latest selection");
            if (rows is not null)
            {
                var selected = list.SelectedItem;
                typeof(ViewModels.ShellViewModel).GetProperty("SelectedChat")!.SetValue(_viewModel, selected);
                var reordered = rows.ToList();
                var moved = reordered[2]; reordered.RemoveAt(2); reordered.Insert(0, moved);
                rows.Apply(reordered, false);
                await Task.Delay(400);
                results.Add($"DETAIL moved expected={(selected as ChatSummary)?.Id} actual={(list.SelectedItem as ChatSummary)?.Id} model={_viewModel?.SelectedChat?.Id} sameReference={ReferenceEquals(selected,list.SelectedItem)} index={list.SelectedIndex}");
                var movedRow = list.ContainerFromItem(list.SelectedItem) as ListViewItem;
                var movedOrigin = movedRow?.TransformToVisual(region).TransformPoint(new Point());
                var movedTop = movedOrigin?.Y + ((movedRow?.ActualHeight ?? 0) - indicator.Height) / 2;
                var inViewport = movedTop is { } top && top + indicator.Height > 0 && top < region.ActualHeight;
                Check(ReferenceEquals(selected, list.SelectedItem) && (inViewport ? Aligned() : indicator.Visibility == Visibility.Collapsed),
                    "collection move preserves selected identity and viewport-correct indicator");
                list.ScrollIntoView(rows[^1], ScrollIntoViewAlignment.Leading);
                await Task.Delay(500);
                Check(indicator.Visibility == Visibility.Collapsed, "offscreen selected row has no stray indicator");
                list.ScrollIntoView(selected, ScrollIntoViewAlignment.Leading);
                await Task.Delay(500);
                Check(Aligned(), "scrolling back restores the correct indicator");
            }
            var previousHeight = region.Height;
            region.Height = 350;
            await Task.Delay(400);
            Check(Aligned(), "viewport resize re-anchors without a stale animation");
            region.Height = previousHeight;
            list.SelectedItem = null;
            await Task.Delay(400);
            Check(indicator.Visibility == Visibility.Collapsed, "clearing selection removes the indicator");
            list.SelectedIndex = 1;
            await Task.Delay(400);
            Check(Aligned(), "selection returns after clearing");
        }
        catch (Exception error) { results.Add("FAIL " + error); }
        File.WriteAllLines(Path.Combine(AppContext.BaseDirectory,
            $"selection-{(settings ? "settings" : "chats")}-{ActualTheme}.log"), results);
    }
}
